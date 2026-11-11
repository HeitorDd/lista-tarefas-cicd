<#
  Configuracao inicial (rodar UMA vez). Pode rodar de novo sem problema: o que ja existe e mantido.

  Cria na AWS:
    - repositorio de imagens no ECR (com scan de vulnerabilidades)
    - uma tabela DynamoDB por ambiente (dev, hml, prd)
    - uma role por ambiente para a aplicacao acessar SO a tabela do seu ambiente
    - a ligacao GitHub -> AWS por OIDC (sem chave guardada) e a role usada pelo pipeline

  Configura no GitHub:
    - variaveis do repositorio (AWS_ROLE_ARN, AWS_REGION, ECR_REPOSITORY)
    - environments dev, homologacao e producao (producao exige sua aprovacao)
    - regra na main: so entra codigo por pull request com o CI passando

  Como rodar (PowerShell, na pasta do repositorio):
    Set-ExecutionPolicy -Scope Process Bypass
    .\infra\setup.ps1
#>
param(
    [string]$Regiao = "us-east-2",
    [string]$App = "lista-tarefas"
)

. "$PSScriptRoot\comum.ps1"

Passo "Conferindo acessos"
$Conta = ObterConta
$Repo = ObterRepoGitHub
Ok "Conta AWS encontrada"
Ok "Repositorio GitHub: $Repo"

# ---------------------------------------------------------------- ECR
Passo "Repositorio de imagens (ECR): $App"
aws ecr describe-repositories --repository-names $App --region $Regiao 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws ecr create-repository --repository-name $App --region $Regiao --image-scanning-configuration "scanOnPush=true" | Out-Null
    if ($LASTEXITCODE -ne 0) { Falha "Nao consegui criar o repositorio no ECR." }
    Ok "criado"
} else {
    aws ecr put-image-scanning-configuration --repository-name $App --region $Regiao --image-scanning-configuration "scanOnPush=true" | Out-Null
    Ok "ja existia (scan no push garantido)"
}
$politicaCiclo = SalvarJson "ecr-ciclo.json" @{
    rules = @(
        @{
            rulePriority = 1
            description  = "Apaga imagens sem tag depois de 7 dias"
            selection    = @{ tagStatus = "untagged"; countType = "sinceImagePushed"; countUnit = "days"; countNumber = 7 }
            action       = @{ type = "expire" }
        }
    )
}
aws ecr put-lifecycle-policy --repository-name $App --region $Regiao --lifecycle-policy-text $politicaCiclo | Out-Null
Ok "regra de limpeza de imagens antigas aplicada"

# ---------------------------------------------------------------- Roles padrao do ECS Express
Passo "Roles padrao do ECS Express Mode"
$confiancaTarefas = SalvarJson "confianca-ecs-tasks.json" @{
    Version   = "2012-10-17"
    Statement = @(@{ Effect = "Allow"; Principal = @{ Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" })
}
$confiancaEcs = SalvarJson "confianca-ecs.json" @{
    Version   = "2012-10-17"
    Statement = @(@{ Effect = "Allow"; Principal = @{ Service = "ecs.amazonaws.com" }; Action = "sts:AssumeRole" })
}
aws iam get-role --role-name ecsTaskExecutionRole 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document $confiancaTarefas | Out-Null
    aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    Ok "ecsTaskExecutionRole criada"
} else { Ok "ecsTaskExecutionRole ja existia" }

aws iam get-role --role-name ecsInfrastructureRoleForExpressServices 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws iam create-role --role-name ecsInfrastructureRoleForExpressServices --assume-role-policy-document $confiancaEcs | Out-Null
    aws iam attach-role-policy --role-name ecsInfrastructureRoleForExpressServices --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
    Ok "ecsInfrastructureRoleForExpressServices criada"
} else { Ok "ecsInfrastructureRoleForExpressServices ja existia" }

# ---------------------------------------------------------------- DynamoDB + role da aplicacao
foreach ($amb in $Ambientes.Keys) {
    $tabela = "$App-$amb"
    Passo "Ambiente ${amb}: tabela DynamoDB e role da aplicacao"

    aws dynamodb describe-table --table-name $tabela --region $Regiao 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        aws dynamodb create-table --table-name $tabela --region $Regiao `
            --attribute-definitions "AttributeName=id,AttributeType=S" `
            --key-schema "AttributeName=id,KeyType=HASH" `
            --billing-mode PAY_PER_REQUEST | Out-Null
        if ($LASTEXITCODE -ne 0) { Falha "Nao consegui criar a tabela $tabela." }
        Ok "tabela $tabela criada (cobranca por uso)"
    } else { Ok "tabela $tabela ja existia" }

    $roleTarefa = "$App-task-$amb"
    aws iam get-role --role-name $roleTarefa 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        aws iam create-role --role-name $roleTarefa --assume-role-policy-document $confiancaTarefas | Out-Null
        if ($LASTEXITCODE -ne 0) { Falha "Nao consegui criar a role $roleTarefa." }
        Ok "role $roleTarefa criada"
    } else { Ok "role $roleTarefa ja existia" }

    $politicaTabela = SalvarJson "politica-$amb.json" @{
        Version   = "2012-10-17"
        Statement = @(@{
                Effect   = "Allow"
                Action   = @("dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Scan", "dynamodb:Query", "dynamodb:DescribeTable")
                Resource = "arn:aws:dynamodb:${Regiao}:${Conta}:table/$tabela"
            })
    }
    aws iam put-role-policy --role-name $roleTarefa --policy-name "acesso-$tabela" --policy-document $politicaTabela
    if ($LASTEXITCODE -ne 0) { Falha "Nao consegui dar acesso a tabela para $roleTarefa." }
    Ok "$roleTarefa acessa somente a tabela $tabela"
}

# ---------------------------------------------------------------- OIDC GitHub -> AWS
Passo "Ligacao GitHub -> AWS (OIDC)"
$provedorArn = "arn:aws:iam::${Conta}:oidc-provider/token.actions.githubusercontent.com"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn $provedorArn 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws iam create-open-id-connect-provider `
        --url "https://token.actions.githubusercontent.com" `
        --client-id-list "sts.amazonaws.com" `
        --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd | Out-Null
    if ($LASTEXITCODE -ne 0) { Falha "Nao consegui criar o provedor OIDC do GitHub." }
    Ok "provedor OIDC criado"
} else { Ok "provedor OIDC ja existia" }

$roleGitHub = "$App-github-actions"
$confiancaGitHub = SalvarJson "confianca-github.json" @{
    Version   = "2012-10-17"
    Statement = @(@{
            Effect    = "Allow"
            Principal = @{ Federated = $provedorArn }
            Action    = "sts:AssumeRoleWithWebIdentity"
            Condition = @{
                StringEquals = @{ "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
                # So a main e os environments DESTE repositorio podem usar a role
                StringLike   = @{ "token.actions.githubusercontent.com:sub" = @("repo:${Repo}:ref:refs/heads/main", "repo:${Repo}:environment:*") }
            }
        })
}
aws iam get-role --role-name $roleGitHub 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws iam create-role --role-name $roleGitHub --assume-role-policy-document $confiancaGitHub | Out-Null
    if ($LASTEXITCODE -ne 0) { Falha "Nao consegui criar a role $roleGitHub." }
    Ok "role $roleGitHub criada"
} else {
    aws iam update-assume-role-policy --role-name $roleGitHub --policy-document $confiancaGitHub
    Ok "role $roleGitHub ja existia (confianca atualizada)"
}

$politicaPipeline = SalvarJson "politica-pipeline.json" @{
    Version   = "2012-10-17"
    Statement = @(
        @{ Effect = "Allow"; Action = "ecr:GetAuthorizationToken"; Resource = "*" },
        @{
            Effect   = "Allow"
            Action   = @(
                "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
                "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
                "ecr:DescribeImages", "ecr:DescribeImageScanFindings"
            )
            Resource = "arn:aws:ecr:${Regiao}:${Conta}:repository/$App"
        },
        @{
            Effect   = "Allow"
            Action   = @("ecs:DescribeServices", "ecs:UpdateService")
            Resource = "arn:aws:ecs:${Regiao}:${Conta}:service/default/$App-*"
        }
    )
}
aws iam put-role-policy --role-name $roleGitHub --policy-name "pipeline-$App" --policy-document $politicaPipeline
if ($LASTEXITCODE -ne 0) { Falha "Nao consegui aplicar as permissoes do pipeline." }
Ok "pipeline pode: enviar imagens ao ECR e atualizar os servicos $App-*"
$roleGitHubArn = "arn:aws:iam::${Conta}:role/$roleGitHub"

# ---------------------------------------------------------------- GitHub
Passo "GitHub: variaveis do repositorio"
gh variable set AWS_ROLE_ARN --repo $Repo --body $roleGitHubArn
gh variable set AWS_REGION --repo $Repo --body $Regiao
gh variable set ECR_REPOSITORY --repo $Repo --body $App
Ok "AWS_ROLE_ARN, AWS_REGION e ECR_REPOSITORY configuradas"

Passo "GitHub: environments"
$usuarioId = [int64](gh api user --jq .id)
foreach ($amb in $Ambientes.Keys) {
    $nomeGitHub = $Ambientes[$amb]
    if ($amb -eq "prd") {
        $corpo = SalvarJson "env-$nomeGitHub.json" @{
            reviewers           = @(@{ type = "User"; id = $usuarioId })
            prevent_self_review = $false
        }
        gh api -X PUT "repos/$Repo/environments/$nomeGitHub" --input ($corpo -replace "^file://", "") | Out-Null
        Ok "$nomeGitHub (exige sua aprovacao)"
    } else {
        gh api -X PUT "repos/$Repo/environments/$nomeGitHub" | Out-Null
        Ok "$nomeGitHub (automatico)"
    }
}

Passo "GitHub: regra de protecao da main"
$regras = gh api "repos/$Repo/rulesets" --jq ".[].name"
if ($regras -contains "proteger-main") {
    Ok "regra ja existia"
} else {
    $regra = SalvarJson "ruleset-main.json" @{
        name          = "proteger-main"
        target        = "branch"
        enforcement   = "active"
        conditions    = @{ ref_name = @{ include = @("~DEFAULT_BRANCH"); exclude = @() } }
        bypass_actors = @()
        rules         = @(
            @{ type = "deletion" },
            @{ type = "non_fast_forward" },
            @{
                type       = "pull_request"
                parameters = @{
                    required_approving_review_count   = 0
                    dismiss_stale_reviews_on_push     = $false
                    require_code_owner_review         = $false
                    require_last_push_approval        = $false
                    required_review_thread_resolution = $false
                }
            },
            @{
                type       = "required_status_checks"
                parameters = @{
                    strict_required_status_checks_policy = $false
                    required_status_checks               = @(
                        @{ context = "Lint e testes" },
                        @{ context = "Seguranca do codigo" },
                        @{ context = "Build da imagem Docker" }
                    )
                }
            }
        )
    }
    gh api -X POST "repos/$Repo/rulesets" --input ($regra -replace "^file://", "") | Out-Null
    if ($LASTEXITCODE -ne 0) { Aviso "Nao consegui criar a regra da main. Da para criar depois em Settings > Rules." }
    else { Ok "main protegida: so via pull request com o CI passando" }
}

Passo "Pronto!"
Write-Host "Proximos passos:"
Write-Host "  1. No GitHub, abra Actions > Pipeline > Run workflow (para montar a primeira imagem)."
Write-Host "  2. Depois, ligue os ambientes:  .\infra\ambientes.ps1 -Acao ligar -Ambiente dev"
