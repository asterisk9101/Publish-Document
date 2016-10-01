﻿[System.Collections.Stack]$circle   # グラフの循環チェック用スタック
[System.Collections.Hashtable]$Dependencies # 依存関係を表すハッシュテーブル
[System.Collections.Hashtable]$Graph    # 依存関係を解決したグラフのノード
[System.Collections.Hashtable]$Exports  # タスク間のデータ交換用コンテナ
[System.Management.Automation.PSCustomObject]$Opts  # オプション解析結果を格納するコンテナ

function Get-Graph {
    param($Target)

    # 循環グラフはエラーとする
    if ($script:circle.Contains($Target)) { throw "circle graph: $Target" }
    $circle.Push($Target) > $null # 循環チェック

    $root = $script:Dependencies[$Target]
    if ($root -eq $null) {
        # Publish ファイルにターゲットが無い場合
        # $Target はファイル名であると判断して、新しくノードを作る
        $root = New-Object System.Collections.Hashtable
        $root.Add("name", $Target) > $null
    } else {
        # Publish ファイルにターゲットがある場合
        # ターゲットを Graph ノードに置換する
        $root.from | ? { $_ } |
        % {
            $children = New-Object System.Collections.ArrayList
        } {
            $children.Add((Get-Graph($_))) > $null
        } {
            $root.from = $children
        }
    }
    $script:circle.Pop() > $null # 循環チェック
    return $root
}
function Compare-Datetime {
    param($node)
    $date1 = Get-ItemPropertyValue -Name LastWriteTime -Path $node["name"]
    $date2 = $node["from"] |
        ? { $_ } |
        ? { Test-Path $_ } |
        % { Get-ItemPropertyValue -Name LastWriteTime -Path $_ } |
        sort |
        select -last 1

    if ($from -eq $Null) {
        return $False
    } else {
        return $date1 -lt $date2
    }
}
function Invoke-Executor {
     param($cmd)
     $result = New-Object PSObject |
        Add-Member -PassThru NoteProperty state $true |
        Add-Member -PassThru NoteProperty output $null

     if ($cmd.GetType().Name -eq "String") {
         Write-Host "> $cmd"
         $result.output = cmd /c $cmd
         $result.state = $?
         Write-Host $result.output
     } else {
         $cmd.keys | Select -First 1 | % {
             Write-Host "> $_ : $($cmd[$_])"
             $result.output = & $_ -Exports $script:Exports -Arguments $cmd[$_]
             $result.state = $?
             Write-Host $result.output
         }
     }
     Write-Host ""
     return $result
}
function Invoke-Task {
    param($node)
    # 実行済みのタスクはスキップする
    if ($node["state"] -eq "executed") {
        Write-Host "Skip: Task $($node.name)"
        return
    } else {
        Write-Host "Call: Task $($node.name)"
    }

    if ((Test-Path $node["name"])) {
        # ターゲットとなるファイルが存在するとき、ファイルの更新日時を比較する。

        # ターゲットの更新日時が依存先の更新日時より古いとき、
        # 依存先のタスクを実行する
        Write-Output 1 |
        ? { Compare-Datetime($node) } |
        % { $node["from"] } |
        ? { $_ } |
        % {
            Invoke-Task($_) > $null
        }
    } else {
        # ターゲットとなるファイルが存在しないとき、依存先タスクを全て実行する
        $node["from"] | ? { $_ } | 
        % {
            Invoke-Task($_) > $null
        }
    }

    # タスクの実行（実行結果が一つでも失敗なら、タスクのステータスは失敗）
    $result = $node["exec"] | ? { $_ } | % { Invoke-Executor($_) }
    $result = $result | ? { -not $_ } | select -first 1
    if ($result) { $node["result"] = $result } else { $node["result"] = "success" }
    
    # タスクのステータスを実行済みに変更
    $node["state"] = "executed"

    return $node["result"]
}
function Test-Task {
    param($graph)
    $graph["from"] | ? { $_ } | % {
        Test-Task($_)
    }
    $graph.exec | ? { $_ } | % {
        if ($_.GetType().Name -eq "String") {
            Write-Output "$_"
        } elseif ($_.GetType().Name -eq "Hashtable") {
            $hash = $_
            $hash.keys | % {
                Write-Output "$_"
                Write-Output $hash[$_]
            }
        } else {
            throw "TypeError"
        }
    }
}
function Show-TaskList {
    param($graph)
    $graph.keys | % {
        $obj = $graph[$_]
        if (-not $obj.hidden) {
            New-Object PSObject |
            Add-Member NoteProperty Name $_ -PassThru |
            Add-Member NoteProperty Description $obj.desc -PassThru 
        }
    }
}
function Publish-Document {
    param(
        $Target = "default",
        $File = ".\Publish",
        [switch]$Test = $false,
        [switch]$List = $false
    )

    # モジュール全体で共用する変数の初期化
    $script:circle = New-Object System.Collections.Stack

    $script:Opts = New-Object psobject |
        Add-Member -PassThru NoteProperty Test $Test |
        Add-Member -PassThru NoteProperty List $List

    $script:Exports = New-Object System.Collections.Hashtable

    # この辺りから Publish ファイルの解析開始
    try {
        $Path = Resolve-Path $File
        $script:Dependencies = Import-YAML $Path
    } catch {
        throw $_
    }

    if ($Opts.List) {
        Show-TaskList $script:Dependencies
        return # return
    }

    # 全てのノードに共通の属性を付与する
    $script:Dependencies.keys |
    % {
        $script:Dependencies[$_].Add("name", $_) # ターゲットの名前もしくは生成するファイルの名前
        $script:Dependencies[$_].Add("state", "wait") # ノードの状態
        $script:Dependencies[$_].Add("result", "") # 実行結果
    }
    $script:Graph = Get-Graph($Target)

    if ($Opts.Test) {
        Test-Task $script:Graph
        return # return
    }

    Invoke-Task $script:Graph # 結果を出力する
}

# モジュールのロード
$modules = New-Object PSObject
$moduleRoot = Split-Path -Path $MyInvocation.MyCommand.Path
"$moduleRoot\Modules\*.psm1" |
? { Test-Path -PathType Container -Path $_ } |
Resolve-Path |
? { -not $_.ProviderPath.ToLower().Contains(".tests.")} |
% { Import-Module -Force $_.ProviderPath }

Export-ModuleMember -Function Publish-Document
