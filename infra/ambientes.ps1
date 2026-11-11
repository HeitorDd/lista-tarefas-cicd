<#
  Liga, desliga ou mostra o status dos ambientes na AWS.

  Exemplos (PowerShell, na pasta do repositorio):
    Set-ExecutionPolicy -Scope Process Bypass
    .\infra\ambientes.ps1 -Acao status
    .\infra\ambientes.ps1 -Acao ligar -Ambiente dev
    .\infra\ambientes.ps1 -Acao ligar -Ambiente todos
    .\infra\ambientes.ps1 -Acao desligar -Ambiente hml

  Ligar: cria o servico no ECS Express Mode usando a imagem marcada para o ambiente
         (dev, hml ou prd) e grava o endereco publico no GitHub (variavel APP_URL).
  Desligar: apaga o servico (para de cobrar). A tabela, a imagem e as roles continuam.
            Ao ligar de novo, o endereco publico muda (e o script atualiza o GitHub).
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("ligar", "desligar", "status")]
    [string]$Acao,

    [ValidateSet("dev", "hml", "prd", "todos")]
    [string]$Ambiente = "todos",

    [string]$Regiao = "us-east-2",
    [string]$App = "lista-tarefas"
)

. "$PSScriptRoot\comum.ps1"

$Conta = ObterConta
$Repo = ObterRepoGitHub

if ($Ambiente -eq "todos") { $lista = @($Ambientes.Keys) } else { $lista = @($Ambiente) }

function ArnServico([string]$amb) {
    return "arn:aws:ecs:${Regiao}:${Conta}:service/default/$App-$amb"
}

function StatusServico([string]$amb) {
    $status = aws ecs describe-services --region $Regiao --cluster default --services "$App-$amb" `
        --query "services[0].status" --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $status -or $status -eq "None") { return "NAO EXISTE" }
    return $status.Trim()
}

function EnderecoServico([string]$amb) {
    $endereco = aws ecs describe-express-gateway-service --region $Regiao --service-arn (ArnServico $amb) `
        --query "service.activeConfigurations[0].ingressPaths[0].endpoint" --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $endereco -or $endereco -eq "None") { return $null }
    $endereco = $endereco.Trim()
    if ($endereco -notmatch "^https?://") { $endereco = "https://$endereco" }
    return $endereco
}

function Ligar([string]$amb) {
    Passo "Ligando $amb"
    $status = StatusServico $amb
    if ($status -eq "ACTIVE") { Ok "ja estava ligado: $(EnderecoServico $amb)"; return }
    if ($status -eq "DRAINING") { Aviso "o servico ainda esta sendo apagado. Espere alguns minutos e tente de novo."; return }

    aws ecr describe-images --region $Regiao --repository-name $App --image-ids "imageTag=$amb" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Aviso "ainda nao existe imagem marcada como '$amb'. Rode o pipeline no GitHub (e aprove a producao, se for o caso) antes de ligar."
        return
    }

    $container = SalvarJson "container-$amb.json" @{
        image         = "${Conta}.dkr.ecr.${Regiao}.amazonaws.com/${App}:$amb"
        containerPort = 8000
        environment   = @(
            @{ name = "APP_ENV"; value = $amb },
            @{ name = "TABLE_NAME"; value = "$App-$amb" },
            @{ name = "AWS_DEFAULT_REGION"; value = $Regiao }
        )
    }
    $escala = SalvarJson "escala.json" @{ minTaskCount = 1; maxTaskCount = 1 }

    $arn = aws ecs create-express-gateway-service --region $Regiao `
        --service-name "$App-$amb" `
        --execution-role-arn "arn:aws:iam::${Conta}:role/ecsTaskExecutionRole" `
        --infrastructure-role-arn "arn:aws:iam::${Conta}:role/ecsInfrastructureRoleForExpressServices" `
        --task-role-arn "arn:aws:iam::${Conta}:role/$App-task-$amb" `
        --primary-container $container `
        --health-check-path "/health" `
        --scaling-target $escala `
        --cpu 256 --memory 512 `
        --query "service.serviceArn" --output text
    if ($LASTEXITCODE -ne 0) { Aviso "a criacao falhou (veja a mensagem acima)."; return }
    Ok "servico criado. Aguardando o endereco publico..."

    $endereco = $null
    for ($i = 1; $i -le 30 -and -not $endereco; $i++) {
        Start-Sleep -Seconds 10
        $endereco = EnderecoServico $amb
    }
    if (-not $endereco) { Aviso "o endereco ainda nao apareceu. Rode '-Acao status' em alguns minutos."; return }

    $ambGitHub = $Ambientes[$amb]
    gh variable set APP_URL --repo $Repo --env $ambGitHub --body $endereco
    Ok "endereco: $endereco"
    Ok "gravado no GitHub (environment $ambGitHub, variavel APP_URL)"
    Write-Host "    O conteiner leva alguns minutos para subir. Depois abra o endereco no navegador."
}

function Desligar([string]$amb) {
    Passo "Desligando $amb"
    $status = StatusServico $amb
    if ($status -ne "ACTIVE") { Ok "ja estava desligado ($status)"; return }

    Write-Host "    Isso apaga o servico $App-$amb (conteiner e endereco publico)." -ForegroundColor Yellow
    Write-Host "    Continuam: a tabela com os dados, a imagem no ECR e as roles." -ForegroundColor Yellow
    $confirmacao = Read-Host "    Para confirmar, digite o nome do ambiente ($amb)"
    if ($confirmacao -ne $amb) { Aviso "cancelado."; return }

    $novoStatus = aws ecs delete-express-gateway-service --region $Regiao --service-arn (ArnServico $amb) `
        --query "service.status.statusCode" --output text
    if ($LASTEXITCODE -ne 0) { Aviso "a exclusao falhou (veja a mensagem acima)."; return }
    Ok "exclusao iniciada ($novoStatus). Em alguns minutos o servico para de cobrar."
}

function MostrarStatus {
    Passo "Status dos ambientes"
    foreach ($amb in $Ambientes.Keys) {
        $status = StatusServico $amb
        $linha = "{0,-4} {1,-11}" -f $amb, $status
        if ($status -eq "ACTIVE") {
            $rodando = aws ecs describe-services --region $Regiao --cluster default --services "$App-$amb" `
                --query "services[0].runningCount" --output text
            $linha += " conteineres: $rodando  $(EnderecoServico $amb)"
        }
        Write-Host "    $linha"
    }
}

switch ($Acao) {
    "ligar" { foreach ($amb in $lista) { Ligar $amb } }
    "desligar" { foreach ($amb in $lista) { Desligar $amb } }
    "status" { MostrarStatus }
}
