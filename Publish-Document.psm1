﻿[System.Collections.Stack]$circle   # グラフの循環チェック用スタック
[System.Collections.Hashtable]$Dependencies # 依存関係を表すハッシュテーブル
[System.Collections.Hashtable]$Graph    # 依存関係を解決したグラフのノード
[System.Collections.Hashtable]$Exports  # タスク間のデータ交換用コンテナ
[System.Management.Automation.PSCustomObject]$Opts  # オプション解析結果を格納するコンテナ

function Write-Log {
    param($Message, $Level = 6)
    $date = Get-Date -UFormat "%Y/%m/%d %T"
    switch ($Level) {
        default { Write-Host -ForegroundColor Green "$date [INFO] $Message" }
        3 { Write-Host -ForegroundColor Magenta "$date [DEBUG] $Message" }
        2 { Write-Host -ForegroundColor Red "$date [ERROR] $Message" }
        1 { Write-Host -ForegroundColor White "$Message" }
    }
}
function New-Graph {
    param([System.String]$Target)

    # 循環グラフはエラーとする
    if ($script:circle.Contains($Target)) { throw "circle graph: $Target" }
    $circle.Push($Target) > $null # 循環チェック

    $root = $script:Dependencies[$Target]
    if ($root -eq $null) {
        # Publishfile にターゲットが無い場合
        # $Target はファイル名であると判断して、新しくノードを作る
        $root = New-Object System.Collections.Hashtable
        $root.Add("name", $Target) > $null
    } else {
        # Publishfile にターゲットがある場合
        # ターゲットを Graph ノードに置換する
        $root.from | ? { $_ } |
        % {
            $children = New-Object System.Collections.ArrayList
        } {
            $children.Add((New-Graph($_))) > $null
        } {
            $root.from = $children
        }
    }
    $script:circle.Pop() > $null # 循環チェック
    return $root
}
function Compare-Datetime {
    param([System.Collections.Hashtable]$node)
    $date1 = Get-ItemPropertyValue -Name LastWriteTime -Path $node["name"]
    $date2 = $node["from"] |
        ? { $_ } |
        ? { Test-Path $_["name"] } |
        % { Get-ItemPropertyValue -Name LastWriteTime -Path $_["name"] } |
        sort |
        select -last 1

    if ($date2 -eq $Null) {
        return $False
    } else {
        return $date1 -lt $date2
    }
}
function Invoke-Executor {
    param(
        [System.String]$name,
        [System.Object]$cmd
    )
    $result = New-Object PSObject |
       Add-Member -PassThru NoteProperty state $true |
       Add-Member -PassThru NoteProperty output $null

    if ($cmd.GetType().Name -eq "String") {
        Write-Log "Task $name > $cmd"
        if (-not $script:Opts.Test) {
            try {
                $result.output = cmd /c $cmd
                $result.state = $?
                if (-not $result.state) { throw "Command Faild: $cmd"}
                Write-Host $result.output
            } catch {
                throw $_
            }
        }
    } else {
        $cmd.keys | Select -First 1 | % {
            Write-Log "Task $name > $_ : $($cmd[$_])"
            if (-not $script:Opts.Test) {
                try {
                    $result.output = & "$prefix$_" -Exports $script:Exports -Arguments $cmd[$_]
                    $result.state = $?
                    if (-not $result.state) { throw "Module Faild: $_ : $($cmd[$_])"}
                    Write-Host $result.output
                } catch {
                    throw $_
                }
            }
        }
    }
    return $result
}
function Invoke-Task {
    param([System.Collections.Hashtable]$node)
    # 実行済みのタスクはスキップする
    if ($node["state"] -eq "executed") {
        Write-Log "Skip: Task $($node.name)"  -Level 3
        return
    }

    if ((Test-Path $node["name"])) {
        Write-Log "Call: Task $($node.name)"
        
        # ターゲットとなるファイルが存在するとき、ファイルの更新日時を比較する。

        # ターゲットの更新日時が依存先の更新日時より古いとき、
        # 依存先のタスクを実行する
        if (Compare-Datetime($node)) {
            $node["from"] | ? { $_ } | % {
                Invoke-Task $_ > $null
            }
        } else {
            $node["from"] | ? { $_ } | % {
                Write-Log "Skip: Task $($_['name'])" -Level 3
            }
        }
    } elseif ($node["from"].Length -gt 0) {
        # ターゲットとなるファイルが存在しないとき、依存先タスクを全て実行する
        Write-Log "Call: Task $($node.name)"
        $node["from"] | ? { $_ } | 
        % {
            Invoke-Task $_ > $null
        }
    } else {
        throw "Missing Target: $($node.name)"
    }

    # タスクの実行（実行結果が一つでも失敗なら、タスクのステータスは失敗）
    $result = $node["exec"] |
        ? { $_ } |
        % {
            # タスクで定義されたコマンドまたはモジュールの実行
            Invoke-Executor $node["name"] $_ } |
        ? { -not $_ } | 
        Select -First 1

    if ($result) {
        $node["result"] = $result
    } else {
        $node["result"] = $result
    }
    
    # タスクの状態を実行済みに変更
    $node["state"] = "executed"

    return $node["result"]
}
function Show-TaskList {
    param([System.Collections.Hashtable]$graph)
    $graph.keys | % {
        $obj = $graph[$_]
        if (-not $obj.hidden) {
            New-Object PSObject |
            Add-Member NoteProperty Name $_ -PassThru |
            Add-Member NoteProperty Description $obj.desc -PassThru 
        }
    }
}

<#
.SYNOPSIS
    GNU make の Powershell 版

.DESCRIPTION
    Publish-Document は GNU make と同様のビルドシステムです。
    ただし、Makefile の代わりに Publishfile を使用します。
    Publishfile の書式は一般的な YAML 形式に従います。詳細は EXAMPLE を参照のこと。

    動作には Import-YAML が必要です。
    https://github.com/asterisk9101/Import-YAML

.PARAMETER Target
    指定されたターゲットからタスクを開始します。

.PARAMETER File
    指定されたファイルを Publishfile として読み込みます。

.PARAMETER Test
    呼び出されるタスクの名前と、そのタスクのコマンドを表示して終了します。
    実際にはコマンドは実行されません。
    依存するタスクのステータスによっては、実際の実行結果と異なる場合があります。

.PARAMETER List
    タスクの一覧を表示して終了します。

.EXAMPLE
    Publish-Document

    Publishfile を読み込んでタスクを実行します。
    ターゲットのタスクが指定されない場合は、デフォルトのタスク default が実行されます。

    典型的な Publishfile のタスクは以下のようなフォーマットで記述されます。

    Task1:
        desc: Task1 description
        from:
            - Task2
            - Task3
        exec:
            - cmdline
            - module_name:
                arg1: "module arguments"

    この時、Task1 はタスクの名前です。
    desc で指定される文字列には、Task1 の説明を記述します。
    from で指定されるリストには、Task1 が依存するタスクの名前を列挙します。
    exec で指定されるリストには、Task1 で実行するコマンドを列挙します。
        このコマンドは from で指定されたタスクのコマンドよりも後に実行されます。
        コマンドを cmdline のように文字列で指定すると、cmd.exe でコマンドが実行されます。
        一方で module_name のようにハッシュで指定すると、Publish-Document の内部で定義されたモジュールが実行されます。
.LINK
    https://github.com/asterisk9101/Publish-Document
#>
function Publish-Document {
    param(
        [System.String]$Target = "default",
        [System.String]$File = ".\Publishfile",
        [switch][System.Boolean]$Test = $false,
        [switch][System.Boolean]$List = $false
    )

    # モジュール全体で共用する変数の初期化
    $script:circle = New-Object System.Collections.Stack

    $script:Opts = New-Object psobject |
        Add-Member -PassThru NoteProperty Test $Test |
        Add-Member -PassThru NoteProperty List $List

    $script:Exports = New-Object System.Collections.Hashtable

    # この辺りから Publishfile の解析開始
    try {
        $Path = Resolve-Path $File
        $script:Dependencies = Import-YAML $Path
    } catch {
        throw $_
    }

    # Publishfile に含まれるタスク一覧を表示して終了する
    if ($Opts.List) {
        Show-TaskList $script:Dependencies
        return # return
    }

    # 全てのノードに共通の属性を付与する
    $script:Dependencies.keys |
    % {
        $script:Dependencies[$_].Add("name", $_) # ターゲットの名前もしくは生成するファイルの名前
        $script:Dependencies[$_].Add("state", "wait") # ノードの状態
        $script:Dependencies[$_].Add("result", $null) # 実行結果
    }

    # 依存関係を解決し、新しくグラフ（DAG）を作る
    $script:Graph = New-Graph $Target

    try {
        Invoke-Task $script:Graph # 結果を出力する
    } catch {
        Write-Error $_
    }
}

# モジュールのロード
$prefix = "Publish-Document_"
$modules = New-Object PSObject
$moduleRoot = Split-Path -Path $MyInvocation.MyCommand.Path
"$moduleRoot\Modules\*.psm1" |
? { Test-Path -PathType Leaf -Path $_ } |
Resolve-Path |
? { -not $_.ProviderPath.ToLower().Contains(".tests.")} |
% { Import-Module -Prefix $prefix -Force $_.ProviderPath }

Export-ModuleMember -Function Publish-Document
