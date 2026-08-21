# ============================================================
# SCRIPT UNIFIE : DORA (REFA) + DSO360 SCA - Detailed Security KPI Extract
# Fusion des scripts "Extraction applications DORA" et
# "Extraction modules et dates de scan DSO360"
# Version : 2.0 - 2026-08-21
# ============================================================
#
# OBJECTIF
# --------
# Centraliser, enrichir et exporter les donnees de conformite des
# applications DORA et de leurs MODULES, en integrant les resultats
# de scans SCA recuperes depuis DSO360, au niveau module (et non plus
# seulement au niveau application comme dans le script 1 original).
#
# DIFFERENCE CLE PAR RAPPORT AU SCRIPT 1 ORIGINAL
# -------------------------------------------------
# Le script 1 original recuperait la liste GLOBALE des scans DSO360
# (endpoint /dso-api/v1/sca/projects/scans, pagine) puis tentait un
# rapprochement CIA -> nom exact -> nom partiel (matching approximatif).
#
# Ce script unifie N'UTILISE PLUS ce rapprochement approximatif : il
# interroge DIRECTEMENT DSO360 par CIA (endpoint
# /dso-api/v1/sca/projects/scans/{cia}, methode du script 2), puisque
# le CIA est deja connu et fiable depuis DORA. Cela elimine tout risque
# de faux-positif/faux-negatif lie a un matching par nom.
#
# ============================================================
# >>> PARAMETRE A CONFIRMER AVANT EXECUTION EN PRODUCTION <<<
# ============================================================
# Le cahier des charges "Logique de Traitement Unifiee" indique :
#   SI characteristicCriteria == "Specific development" -> N/A
#   SINON                                                -> interroger DSO360
#
# Cette regle est INVERSEE par rapport au script 1 original, qui
# n'interrogeait DSO360 QUE pour les applications "Specific development"
# (DEV) - ce qui est le comportement fonctionnellement attendu pour un
# controle SCA (analyse de dependances de code, donc pertinent surtout
# pour du developpement specifique).
#
# Ce script applique PAR DEFAUT la logique du script 1 original
# (DEV interroge DSO360). Si le cahier des charges "Logique Unifiee"
# est bien celui a appliquer tel quel, inversez simplement la valeur
# ci-dessous.
#
# $true  = seules les applications dont la nature est dans
#          $NatureCodesToScan sont interrogees dans DSO360
#          (les autres recoivent N/A)                    [DEFAUT, cf. script 1]
# $false = INVERSE la regle : les applications dont la nature EST dans
#          $NatureCodesToScan recoivent N/A, toutes les AUTRES sont
#          interrogees dans DSO360                       [cf. texte "Logique Unifiee"]
# ------------------------------------------------------------
$ScanOnlyListedNatures = $true
$NatureCodesToScan     = @("DEV")   # codes nature consideres "Specific development"
# ============================================================

# ─────────────────────────────────────────────────────────────
# Forcer l'encodage UTF-8 (console + fichiers) - UTF-8 strict
# ─────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Save-JsonUTF8 {
    param([string]$FilePath, [object]$Data)
    $json = $Data | ConvertTo-Json -Depth 25
    [System.IO.File]::WriteAllText(
        (Join-Path (Get-Location).Path ($FilePath -replace "^\.\\")),
        $json,
        $utf8NoBom
    )
}

# ============================================================
# CONFIGURATION GLOBALE
# ============================================================
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$session.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

$contentType      = "application/json"
$baseUrlDORA      = "https://refa-group.d.bbg"
$baseUrlDSO360    = "https://dso360.mycloud.intranatixis.com"
$baseUrlDSO360API = "https://tes.mycloud.intranatixis.com"
$pageSize         = 50
$moduleQuerySize  = 500     # taille de page pour la requete de modules par CIA (script 2)
$timestamp        = Get-Date -Format "yyyyMMdd_HHmmss"
$dateDay          = Get-Date -Format "dd"

# Fichier de sortie unique (nom impose par la spec fonctionnelle)
$outputPathJSON = ".\DETAILED_DATA_EXTRACT_SCA_KPI_${dateDay}_${timestamp}.json"
$outputPathCSV  = ".\DETAILED_DATA_EXTRACT_SCA_KPI_Modules_${dateDay}_${timestamp}.csv"

# ============================================================
# FONCTIONS UTILITAIRES JWT (reprises du script 1)
# ============================================================

function Decode-JWTInfo {
    param([string]$Token)
    try {
        $parts = $Token.Split(".")
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1]
        $padded  = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, "=")
        $padded  = $padded -replace "-", "+" -replace "_", "/"
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($padded))
        return $decoded | ConvertFrom-Json
    }
    catch { return $null }
}

function Show-TokenInfo {
    param([string]$Token, [string]$SystemName)

    Write-Host ""
    Write-Host "  Informations du token [$SystemName] :" -ForegroundColor Cyan

    $jwtData = Decode-JWTInfo -Token $Token
    if ($null -eq $jwtData) {
        Write-Host "  (Impossible de decoder les informations du token)" -ForegroundColor Gray
        return $true
    }

    if ($jwtData.given_name -and $jwtData.family_name) {
        Write-Host "  Utilisateur  : $($jwtData.given_name) $($jwtData.family_name)" -ForegroundColor White
    }
    elseif ($jwtData.name) {
        Write-Host "  Utilisateur  : $($jwtData.name)" -ForegroundColor White
    }
    elseif ($jwtData.preferred_username) {
        Write-Host "  Login        : $($jwtData.preferred_username)" -ForegroundColor White
    }

    if ($jwtData.email) {
        Write-Host "  Email        : $($jwtData.email)" -ForegroundColor White
    }

    if ($jwtData.exp) {
        $expDate   = [System.DateTimeOffset]::FromUnixTimeSeconds($jwtData.exp).ToLocalTime()
        $now       = [System.DateTimeOffset]::Now
        $remaining = $expDate - $now

        if ($remaining.TotalMinutes -lt 0) {
            Write-Host "  Expiration   : EXPIRE depuis $([Math]::Abs([int]$remaining.TotalMinutes)) minutes" -ForegroundColor Red
            return $false
        }
        elseif ($remaining.TotalMinutes -lt 10) {
            Write-Host "  Expiration   : dans $([int]$remaining.TotalMinutes) min - ATTENTION bientot expire" -ForegroundColor Red
        }
        else {
            Write-Host "  Expiration   : $($expDate.ToString('yyyy-MM-dd HH:mm:ss')) (dans $([int]$remaining.TotalHours)h $($remaining.Minutes)min)" -ForegroundColor Green
        }
    }
    return $true
}

function Get-BearerToken {
    param(
        [string]$SystemName,
        [string]$SystemUrl,
        [string]$Instructions
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " AUTHENTIFICATION : $SystemName" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host $Instructions -ForegroundColor White
    Write-Host ""
    Write-Host "Ouverture du navigateur sur : $SystemUrl" -ForegroundColor Yellow

    try {
        Start-Process $SystemUrl
        Write-Host "OK - Navigateur ouvert." -ForegroundColor Green
    }
    catch {
        Write-Warning "Impossible d'ouvrir le navigateur automatiquement."
        Write-Host "Ouvrez manuellement : $SystemUrl" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan

    $token       = ""
    $attempt     = 0
    $maxAttempts = 3

    while ($token -eq "" -and $attempt -lt $maxAttempts) {
        $attempt++
        Write-Host ""
        Write-Host "Tentative $attempt / $maxAttempts" -ForegroundColor Yellow
        Write-Host "Collez le token Authorization complet (Bearer eyJ...) :" -ForegroundColor White
        Write-Host "(Le token ne s'affichera pas a l'ecran pour securite)" -ForegroundColor Gray
        Write-Host ""

        $secureToken = Read-Host -AsSecureString "Token $SystemName"

        $bstr       = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        $tokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        $tokenPlain = $tokenPlain.Trim()
        $tokenPlain = $tokenPlain -replace "[\r\n]", ""

        if ($tokenPlain -match "^(?i)Bearer\s+(.+)$") {
            $tokenPlain = $Matches[1].Trim()
        }

        if ([string]::IsNullOrWhiteSpace($tokenPlain)) {
            Write-Warning "Token vide. Veuillez reessayer."
            continue
        }

        $token = $tokenPlain
        Write-Host ""
        Write-Host "OK - Token [$SystemName] accepte." -ForegroundColor Green

        $valid = Show-TokenInfo -Token $token -SystemName $SystemName
        if ($valid -eq $false) {
            Write-Warning "Token expire. Obtenez un nouveau token et reessayez."
            $token = ""
        }
    }

    if ($token -eq "") {
        Write-Error "ERREUR - Token [$SystemName] invalide apres $maxAttempts tentatives."
        exit 1
    }

    return $token
}

# ============================================================
# FONCTIONS UTILITAIRES MODULES DSO360 (reprises/adaptees du script 2)
# ============================================================

function Get-ModuleList {
    param($jsonData)
    if (-not $jsonData) { return @() }
    if ($jsonData.content -is [array] -and $jsonData.content.Count -gt 0)   { return $jsonData.content }
    elseif ($jsonData.modules -is [array] -and $jsonData.modules.Count -gt 0) { return $jsonData.modules }
    elseif ($jsonData -is [array] -and $jsonData.Count -gt 0)               { return $jsonData }
    else { return @() }
}

function Get-LastScanDate {
    param($module)
    $candidats = @(
        "lastScanDate", "last_scan_date", "lastScan",
        "scanDate", "scan_date", "updatedAt",
        "updated_at", "dateLastScan", "lastAnalysisDate"
    )
    foreach ($champ in $candidats) {
        $valeur = $module.$champ
        if ($null -ne $valeur -and $valeur -ne "") { return $valeur }
    }
    return "N/A"
}

function Get-ModuleName {
    param($module)
    if ($module.name)        { return $module.name }
    if ($module.moduleName)  { return $module.moduleName }
    if ($module.projectName) { return $module.projectName }
    if ($module.id)          { return "ID:$($module.id)" }
    return "Inconnu"
}

function Get-ModuleStatus {
    param($module)
    if ($module.status) { return $module.status }
    return "N/A"
}

function Get-ModuleVersion {
    param($module)
    if ($module.version) { return $module.version }
    return "N/A"
}

# Interroge DSO360 pour UN cia donne (methode script 2 : POST par CIA)
# Retourne un objet structure : ScanExist, GlobalStatus, GlobalLastScan, NbModules, Modules[], RawEntry
function Get-DSO360ModulesForCia {
    param(
        [string]$Cia,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [hashtable]$Headers,
        [int]$PageSize = 500
    )

    $result = [PSCustomObject]@{
        ScanExist      = $false
        GlobalStatus   = "N/A"
        GlobalLastScan = "N/A"
        NbModules      = 0
        ModuleNames    = @()
        Modules        = @()
        ErrorMessage   = $null
        RawEntry       = $null
    }

    $uri = "$baseUrlDSO360API/dso-api/v1/sca/projects/scans/${Cia}?page=0&size=${PageSize}"

    $bodyObject = @{
        id         = 0
        type       = $null
        page       = 0
        size       = [int]$PageSize
        filtersMap = @{}
    }
    $bodyJson = $bodyObject | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri `
            -Method "POST" `
            -WebSession $Session `
            -Headers $Headers `
            -ContentType "application/json" `
            -Body $bodyJson

        $jsonData = $response.Content | ConvertFrom-Json
        $result.RawEntry = $jsonData

        # Detection application inexistante dans la reponse elle-meme
        $appInexistante = $false
        if ($null -eq $jsonData) { $appInexistante = $true }
        elseif ($jsonData.PSObject.Properties.Name -contains "error"   -and $jsonData.error   -match "not found") { $appInexistante = $true }
        elseif ($jsonData.PSObject.Properties.Name -contains "message" -and $jsonData.message -match "not found") { $appInexistante = $true }
        elseif ($jsonData.PSObject.Properties.Name -contains "status"  -and $jsonData.status  -eq 404)            { $appInexistante = $true }

        if ($appInexistante) {
            $result.ErrorMessage = "Application non existante dans DSO360"
            return $result
        }

        $listeModules  = Get-ModuleList -jsonData $jsonData
        $nombreModules = $listeModules.Count

        if ($nombreModules -eq 0) {
            $result.ErrorMessage = "Application non existante sur les SCANs du module SCA (0 module)"
            return $result
        }

        $modulesFormatted = @()
        $moduleNames       = @()
        $latestDateParsed  = $null
        $latestDateRaw     = "N/A"

        foreach ($module in $listeModules) {
            $nom     = Get-ModuleName    -module $module
            $lastScan = Get-LastScanDate -module $module
            $status   = Get-ModuleStatus -module $module
            $version  = Get-ModuleVersion -module $module

            $moduleNames += $nom

            $modulesFormatted += [PSCustomObject]@{
                NomModule                = $nom
                Version                  = $version
                Statut                   = $status
                DSO360_SCA_Module_Last   = $lastScan
            }

            # Tentative de determination du dernier scan GLOBAL (le plus recent parmi les modules)
            if ($lastScan -ne "N/A") {
                $parsed = $null
                if ([DateTime]::TryParse($lastScan, [ref]$parsed)) {
                    if ($null -eq $latestDateParsed -or $parsed -gt $latestDateParsed) {
                        $latestDateParsed = $parsed
                        $latestDateRaw    = $lastScan
                    }
                }
            }
        }

        $result.ScanExist      = $true
        $result.NbModules      = $nombreModules
        $result.ModuleNames    = $moduleNames
        $result.Modules        = $modulesFormatted
        $result.GlobalLastScan = $latestDateRaw

        # Statut global consolide : succes uniquement si tous les modules
        # partagent un statut de succes reconnu ; sinon on liste les statuts distincts
        $statutsDistincts = $modulesFormatted.Statut | Sort-Object -Unique
        $statutsSucces    = @("SUCCESS", "SUCCESSFUL", "OK", "COMPLETED", "SUCCES")
        if ($statutsDistincts.Count -eq 1 -and ($statutsDistincts[0].ToUpper() -in $statutsSucces)) {
            $result.GlobalStatus = $statutsDistincts[0]
        }
        elseif ($statutsDistincts.Count -eq 1) {
            $result.GlobalStatus = $statutsDistincts[0]
        }
        else {
            $result.GlobalStatus = ($statutsDistincts -join " | ")
        }

        return $result
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        }

        if ($statusCode -eq 404) {
            $result.ErrorMessage = "Application non existante dans DSO360 (HTTP 404)"
        }
        else {
            $result.ErrorMessage = "Erreur technique : $($_.Exception.Message)"
        }
        return $result
    }
}

# ============================================================
# BANNIERE DE DEMARRAGE
# ============================================================
Clear-Host
Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  SCRIPT UNIFIE : DORA + DSO360 SCA - Detailed KPI Extract" -ForegroundColor Magenta
Write-Host "  Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host ""
if ($ScanOnlyListedNatures) {
    Write-Host "  Regle active : DSO360 interroge UNIQUEMENT pour les natures $($NatureCodesToScan -join ', ')" -ForegroundColor Gray
} else {
    Write-Host "  Regle active : DSO360 interroge pour TOUTES LES NATURES SAUF $($NatureCodesToScan -join ', ')" -ForegroundColor Gray
}
Write-Host ""

# ============================================================
# ETAPE 1 : AUTHENTIFICATION (mutualisee)
# ============================================================

$instructionsDORA = @"
Etapes pour recuperer le token DORA :
  1. Connectez-vous avec vos identifiants sur REFA
  2. Ouvrez les outils developpeur (F12) > Onglet Network
  3. Effectuez une action (recherche d'application)
  4. Cliquez sur une requete API > Headers > Authorization
  5. Copiez la valeur complete (Bearer eyJ...)
"@

$tokenDORA = Get-BearerToken `
    -SystemName   "DORA (REFA)" `
    -SystemUrl    $baseUrlDORA `
    -Instructions $instructionsDORA

$headersDORA = @{
    "Language"           = "en"
    "sec-ch-ua-platform" = "`"Windows`""
    "Authorization"      = "Bearer $tokenDORA"
    "Referer"            = "$baseUrlDORA/"
    "sec-ch-ua"          = "`"Not;A=Brand`";v=`"8`", `"Chromium`";v=`"150`", `"Google Chrome`";v=`"150`""
    "sec-ch-ua-mobile"   = "?0"
    "Accept"             = "application/json, text/plain, */*"
}

$instructionsDSO360 = @"
Etapes pour recuperer le token DSO360 :
  1. Connectez-vous avec vos credentials sur DSO360
  2. Ouvrez les outils developpeur (F12) > Onglet Network
  3. Rafraichissez la page ou effectuez une action
  4. Filtrez les requetes sur 'dso-api'
  5. Cliquez sur une requete > Headers > Authorization
  6. Copiez la valeur complete (Bearer eyJ...)
"@

# Token DSO360 unique, mutualise pour TOUS les appels DSO360 du script
# (remplace le token code en dur du script 2 original - point de securite corrige)
$tokenDSO360 = Get-BearerToken `
    -SystemName   "DSO360" `
    -SystemUrl    $baseUrlDSO360 `
    -Instructions $instructionsDSO360

$headersDSO360 = @{
    "Accept"             = "application/json, text/plain, */*"
    "Accept-Encoding"    = "gzip, deflate, br, zstd"
    "Accept-Language"    = "fr-FR,fr;q=0.9,en-US;q=0.8,en;q=0.7"
    "Authorization"      = "Bearer $tokenDSO360"
    "Origin"             = $baseUrlDSO360
    "Referer"            = "$baseUrlDSO360/"
    "Sec-Fetch-Dest"     = "empty"
    "Sec-Fetch-Mode"     = "cors"
    "Sec-Fetch-Site"     = "same-site"
    "X-Requested-With"   = "XMLHttpRequest"
    "sec-ch-ua"          = "`"Not;A=Brand`";v=`"8`", `"Chromium`";v=`"150`", `"Google Chrome`";v=`"150`""
    "sec-ch-ua-mobile"   = "?0"
    "sec-ch-ua-platform" = "`"Windows`""
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Les deux tokens acceptes. Demarrage du traitement..." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

# ============================================================
# ETAPE 2 : EXTRACTION DES APPLICATIONS DORA + NATURES (Script 1, Partie 1)
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ETAPE 2 : EXTRACTION DES APPLICATIONS DORA" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ----------------------------------------------------------
# DORA - Compte total
# ----------------------------------------------------------
Write-Host ""
Write-Host "[DORA-1] Interrogation de l'API /count..." -ForegroundColor Cyan

$doraCriteriaBlock = (
    "`"doraCriteria`":{`"isCurrentVersion`":true,`"doraValueList`":[" +
    "{`"id`":1,`"label`":{`"labelEn`":`"DORA Group Core`",`"labelFr`":`"DORA Groupe c$([char]339)ur`"},`"validityEnd`":null}," +
    "{`"id`":2,`"label`":{`"labelEn`":`"DORA Group Satellite`",`"labelFr`":`"DORA Groupe satellites`"},`"validityEnd`":null}," +
    "{`"id`":3,`"label`":{`"labelEn`":`"DORA Group technical base`",`"labelFr`":`"DORA Groupe socle technique`"},`"validityEnd`":null}," +
    "{`"id`":4,`"label`":{`"labelEn`":`"DORA Local`",`"labelFr`":`"DORA Local`"},`"validityEnd`":null}]}"
)

$statusesBlock = (
    "`"statuses`":[{`"code`":`"PRD`",`"label`":{`"labelEn`":`"Deployed`",`"labelFr`":`"En production`"}," +
    "`"validityEnd`":null,`"isForActiveApps`":true,`"legacyCode`":`"SA1`"}," +
    "{`"code`":`"DEV`",`"label`":{`"labelEn`":`"In development`",`"labelFr`":`"En d$([char]233)veloppement`"}," +
    "`"validityEnd`":null,`"isForActiveApps`":true,`"legacyCode`":`"SA2`"}]"
)

$bodyCount = [System.Text.Encoding]::UTF8.GetBytes(
    "{`"groupId`":null,`"editors`":null,`"localId`":{`"value`":null,`"isExact`":true}," +
    "`"cia`":null,`"name`":{`"value`":null,`"isExact`":false},`"states`":null," +
    "$statusesBlock," +
    "`"type`":null,`"levels`":null,`"responsibleEntities`":null," +
    "`"paging`":{`"pageNumber`":1,`"pageSize`":50}," +
    "`"ordering`":[{`"property`":`"groupId`",`"direction`":`"ASC`"}]," +
    "$doraCriteriaBlock}"
)

try {
    $countResponse = Invoke-WebRequest -UseBasicParsing `
        -Uri "$baseUrlDORA/api/application/count" `
        -Method "POST" `
        -WebSession $session `
        -Headers $headersDORA `
        -ContentType $contentType `
        -Body $bodyCount

    $totalApps = $countResponse.Content | ConvertFrom-Json
    Write-Host "OK - Nombre total d'applications DORA : $totalApps" -ForegroundColor Green
}
catch {
    Write-Error "ERREUR lors de l'appel /count DORA : $_"
    exit 1
}

# ----------------------------------------------------------
# DORA - Pagination / liste complete
# ----------------------------------------------------------
Write-Host ""
Write-Host "[DORA-2] Recuperation de toutes les applications DORA..." -ForegroundColor Cyan

$totalPagesDORA = [Math]::Ceiling($totalApps / $pageSize)
$allAppsDORA    = @()

Write-Host "Pages a recuperer : $totalPagesDORA (pageSize = $pageSize)" -ForegroundColor White

for ($page = 1; $page -le $totalPagesDORA; $page++) {

    Write-Host "  -> Page $page / $totalPagesDORA ..." -ForegroundColor Yellow

    $bodySearch = [System.Text.Encoding]::UTF8.GetBytes(
        "{`"groupId`":null,`"editors`":null,`"localId`":{`"value`":null,`"isExact`":true}," +
        "`"cia`":null,`"name`":{`"value`":null,`"isExact`":false},`"states`":null," +
        "$statusesBlock," +
        "`"type`":null,`"levels`":null,`"responsibleEntities`":null," +
        "`"paging`":{`"pageNumber`":$page,`"pageSize`":$pageSize}," +
        "`"ordering`":[{`"property`":`"groupId`",`"direction`":`"ASC`"}]," +
        "$doraCriteriaBlock}"
    )

    try {
        $searchResponse = Invoke-WebRequest -UseBasicParsing `
            -Uri "$baseUrlDORA/api/application/search" `
            -Method "POST" `
            -WebSession $session `
            -Headers $headersDORA `
            -ContentType $contentType `
            -Body $bodySearch

        $pageData = $searchResponse.Content | ConvertFrom-Json

        if ($pageData -is [Array])           { $allAppsDORA += $pageData }
        elseif ($null -ne $pageData.results) { $allAppsDORA += $pageData.results }
        else                                 { $allAppsDORA += $pageData }

        Write-Host "    OK - $($allAppsDORA.Count) apps au total." -ForegroundColor Green
    }
    catch {
        Write-Error "ERREUR page $page DORA : $_"
        break
    }
}

# ----------------------------------------------------------
# DORA - Recuperation des natures (DEV / SFT / SPE / NOC)
# ----------------------------------------------------------
Write-Host ""
Write-Host "[DORA-3] Recuperation des natures de developpement..." -ForegroundColor Cyan

$appNaturesMap = @{}

$naturesConfig = @(
    @{ code = "DEV"; labelEn = "Specific development";                    labelFr = "D$([char]233)veloppement sp$([char]233)cifique";              legacyCode = "D$([char]233)veloppement Sp$([char]233)cifique" },
    @{ code = "NOC"; labelEn = "Not Concerned";                           labelFr = "Non Concern$([char]233)";                                     legacyCode = "Non Concern$([char]233)" },
    @{ code = "SFT"; labelEn = "Software package";                        labelFr = "Progiciel";                                                   legacyCode = "Progiciel" },
    @{ code = "SPE"; labelEn = "Service provided by external supplier";   labelFr = "Service fourni par un prestataire externe";                   legacyCode = "Service Prestataire Ext" }
)

foreach ($nat in $naturesConfig) {
    Write-Host "  -> Nature [$($nat.code)] $($nat.labelEn)..." -ForegroundColor Yellow

    $bodyNature = [System.Text.Encoding]::UTF8.GetBytes(
        "{`"groupId`":null,`"editors`":null,`"localId`":{`"value`":null,`"isExact`":true}," +
        "`"cia`":null,`"name`":{`"value`":null,`"isExact`":false},`"states`":null," +
        "$statusesBlock," +
        "`"type`":null,`"levels`":null,`"responsibleEntities`":null,`"paging`":{`"pageNumber`":1,`"pageSize`":9999}," +
        "`"ordering`":[{`"property`":`"groupId`",`"direction`":`"ASC`"}]," +
        "`"characteristicCriteria`":{`"isCurrentVersion`":true,`"natures`":[{`"code`":`"$($nat.code)`"," +
        "`"label`":{`"labelEn`":`"$($nat.labelEn)`",`"labelFr`":`"$($nat.labelFr)`"}," +
        "`"validityEnd`":null,`"legacyCode`":`"$($nat.legacyCode)`"," +
        "`"modifiedBy`":{`"id`":`"58528T`"},`"modifiedOn`":1776076193000,`"status`":`"ACTIVE`"}]}," +
        "$doraCriteriaBlock}"
    )

    try {
        $natResponse = Invoke-WebRequest -UseBasicParsing `
            -Uri "$baseUrlDORA/api/application/search" `
            -Method "POST" `
            -WebSession $session `
            -Headers $headersDORA `
            -ContentType $contentType `
            -Body $bodyNature

        $natData = $natResponse.Content | ConvertFrom-Json
        $natList = if ($natData -is [Array])           { $natData }
                   elseif ($null -ne $natData.results) { $natData.results }
                   else                                { $natData }

        $count = 0
        foreach ($app in $natList) {
            $ciaKey = if ($app.cia) { $app.cia } else { $app.groupId }
            if ([string]::IsNullOrWhiteSpace($ciaKey)) { continue }

            if (-not $appNaturesMap.ContainsKey($ciaKey)) {
                $appNaturesMap[$ciaKey] = [System.Collections.Generic.List[object]]::new()
            }

            $appNaturesMap[$ciaKey].Add([PSCustomObject]@{
                code       = $nat.code
                labelEn    = $nat.labelEn
                labelFr    = $nat.labelFr
                legacyCode = $nat.legacyCode
            })
            $count++
        }
        Write-Host "     OK - $count application(s) trouvees." -ForegroundColor Green
    }
    catch {
        Write-Warning "     ATTENTION - Erreur [$($nat.code)] : $_"
    }
}

$appsWithNature    = ($appNaturesMap.Keys | Measure-Object).Count
$appsWithoutNature = $allAppsDORA.Count - $appsWithNature

Write-Host ""
Write-Host "  Resume natures :" -ForegroundColor Cyan
Write-Host "  -> $appsWithNature avec nature identifiee" -ForegroundColor White
Write-Host "  -> $appsWithoutNature sans nature identifiee" -ForegroundColor White

# ----------------------------------------------------------
# DORA - Fusion DORA + natures -> liste pilote pour l'etape DSO360
# ----------------------------------------------------------
Write-Host ""
Write-Host "[DORA-4] Fusion des donnees DORA + natures..." -ForegroundColor Cyan

$enrichedAppsDORA = [System.Collections.Generic.List[object]]::new()

foreach ($app in $allAppsDORA) {

    $ciaKey = if ($app.cia) { $app.cia } else { $app.groupId }

    if (-not [string]::IsNullOrWhiteSpace($ciaKey) -and $appNaturesMap.ContainsKey($ciaKey)) {
        $naturesFound = $appNaturesMap[$ciaKey]
        $codes        = ($naturesFound | ForEach-Object { $_.code })    -join " | "
        $labelsEn     = ($naturesFound | ForEach-Object { $_.labelEn }) -join " | "
        $labelsFr     = ($naturesFound | ForEach-Object { $_.labelFr }) -join " | "

        $criteriaValue = [PSCustomObject]@{
            isCurrentVersion = $true
            natures          = $naturesFound
            hasNature        = $true
            natureSummary    = [PSCustomObject]@{ codes = $codes; labelsEn = $labelsEn; labelsFr = $labelsFr }
        }
    }
    else {
        $criteriaValue = [PSCustomObject]@{
            isCurrentVersion = $true
            natures          = @()
            hasNature        = $false
            natureSummary    = [PSCustomObject]@{
                codes    = ""
                labelsEn = "No development nature identified"
                labelsFr = "Aucune nature de developpement identifiee"
            }
        }
    }

    # On conserve TOUTES les donnees brutes DORA, sans modification des libelles
    $enrichedApp = $app | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $enrichedApp | Add-Member -NotePropertyName "cia_key"                -NotePropertyValue $ciaKey        -Force
    $enrichedApp | Add-Member -NotePropertyName "characteristicCriteria" -NotePropertyValue $criteriaValue -Force
    $enrichedApp | Add-Member -NotePropertyName "extractionDate"         -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force

    # Champs DSO360 (niveau application + niveau module) - initialises a N/A
    $enrichedApp | Add-Member -NotePropertyName "DSO360_ScanExist"              -NotePropertyValue "N/A" -Force
    $enrichedApp | Add-Member -NotePropertyName "DSO360_ScanStatus"             -NotePropertyValue "N/A" -Force
    $enrichedApp | Add-Member -NotePropertyName "DSO360_SCA_Globale_LastScan"   -NotePropertyValue "N/A" -Force
    $enrichedApp | Add-Member -NotePropertyName "NB_Modules"                    -NotePropertyValue "N/A" -Force
    $enrichedApp | Add-Member -NotePropertyName "Liste_Modules"                 -NotePropertyValue @()   -Force
    $enrichedApp | Add-Member -NotePropertyName "Modules"                       -NotePropertyValue @()   -Force
    $enrichedApp | Add-Member -NotePropertyName "DSO360_TraitementApplique"     -NotePropertyValue $false -Force
    $enrichedApp | Add-Member -NotePropertyName "DSO360_ErrorMessage"           -NotePropertyValue $null -Force

    $enrichedAppsDORA.Add($enrichedApp)
}

Write-Host "OK - $($enrichedAppsDORA.Count) applications DORA enrichies avec natures." -ForegroundColor Green

# ============================================================
# ETAPE 3 : ENRICHISSEMENT DSO360 PAR MODULE (Script 2, applique en boucle)
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ETAPE 3 : EXTRACTION DES MODULES DSO360 PAR APPLICATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$totalApplications = $enrichedAppsDORA.Count
$compteur           = 0
$appsTraitees        = 0
$appsIgnoreesNA      = 0
$appsAvecModules     = 0
$appsNonExistantes   = 0
$appsErreur          = 0
$totalModulesExtraits = 0
$tousLesModulesFlat   = @()   # pour export CSV a plat

foreach ($doraApp in $enrichedAppsDORA) {

    $compteur++
    $ratio = "[$compteur/$totalApplications]"

    $codesNature = @()
    if ($doraApp.characteristicCriteria -and $doraApp.characteristicCriteria.natures) {
        $codesNature = $doraApp.characteristicCriteria.natures | ForEach-Object { $_.code }
    }

    $estDansListe = ($codesNature | Where-Object { $_ -in $NatureCodesToScan } | Measure-Object).Count -gt 0

    # Determine si CETTE application doit etre interrogee dans DSO360,
    # selon le sens de la regle choisi en tete de script
    if ($ScanOnlyListedNatures) {
        $doitInterrogerDSO360 = $estDansListe
    } else {
        $doitInterrogerDSO360 = -not $estDansListe
    }

    $ciaKey = $doraApp.cia_key

    if (-not $doitInterrogerDSO360) {
        # Application hors perimetre de scan DSO360 : tous les champs restent N/A
        $appsIgnoreesNA++
        Write-Host "$ratio $ciaKey  ==>  Hors perimetre DSO360 (N/A)" -ForegroundColor DarkGray
        continue
    }

    $appsTraitees++

    Write-Host ""
    Write-Host "$ratio Interrogation DSO360 pour   " -ForegroundColor Cyan -NoNewline
    Write-Host "$ciaKey" -ForegroundColor White -NoNewline
    Write-Host "  ==>  " -ForegroundColor Cyan -NoNewline

    if ([string]::IsNullOrWhiteSpace($ciaKey)) {
        Write-Host "CIA manquant - ignore" -ForegroundColor Red
        $doraApp.DSO360_TraitementApplique = $true
        $doraApp.DSO360_ScanExist          = "Non"
        $doraApp.DSO360_ErrorMessage       = "CIA manquant cote DORA"
        $appsErreur++
        continue
    }

    $moduleResult = Get-DSO360ModulesForCia -Cia $ciaKey -Session $session -Headers $headersDSO360 -PageSize $moduleQuerySize

    $doraApp.DSO360_TraitementApplique = $true

    if (-not $moduleResult.ScanExist) {
        Write-Host "$($moduleResult.ErrorMessage)" -ForegroundColor DarkYellow
        $doraApp.DSO360_ScanExist            = "Non"
        $doraApp.DSO360_ScanStatus           = "N/A"
        $doraApp.DSO360_SCA_Globale_LastScan = "N/A"
        $doraApp.NB_Modules                  = 0
        $doraApp.Liste_Modules               = @()
        $doraApp.Modules                     = @()
        $doraApp.DSO360_ErrorMessage         = $moduleResult.ErrorMessage
        $appsNonExistantes++
        continue
    }

    Write-Host "Succes - $($moduleResult.NbModules) module(s) trouve(s)" -ForegroundColor Green

    $doraApp.DSO360_ScanExist            = "Oui"
    $doraApp.DSO360_ScanStatus           = $moduleResult.GlobalStatus
    $doraApp.DSO360_SCA_Globale_LastScan = $moduleResult.GlobalLastScan
    $doraApp.NB_Modules                  = $moduleResult.NbModules
    $doraApp.Liste_Modules               = $moduleResult.ModuleNames
    $doraApp.Modules                     = $moduleResult.Modules

    $appsAvecModules      += 1
    $totalModulesExtraits += $moduleResult.NbModules

    foreach ($mod in $moduleResult.Modules) {
        $tousLesModulesFlat += [PSCustomObject]@{
            CIA                    = $ciaKey
            NomApplication         = $doraApp.name
            NomModule              = $mod.NomModule
            Version                = $mod.Version
            Statut                 = $mod.Statut
            DSO360_SCA_Module_Last = $mod.DSO360_SCA_Module_Last
        }
    }
}

Write-Host ""
Write-Host "  Resume enrichissement DSO360 :" -ForegroundColor Cyan
Write-Host "  -> Total apps DORA                       : $($enrichedAppsDORA.Count)" -ForegroundColor White
Write-Host "  -> Apps hors perimetre DSO360 (N/A)      : $appsIgnoreesNA" -ForegroundColor White
Write-Host "  -> Apps interrogees dans DSO360           : $appsTraitees" -ForegroundColor White
Write-Host "  -> ... avec modules trouves (Succes)      : $appsAvecModules" -ForegroundColor Green
Write-Host "  -> ... non existantes dans DSO360          : $appsNonExistantes" -ForegroundColor DarkYellow
Write-Host "  -> ... en erreur technique                 : $appsErreur" -ForegroundColor Red
Write-Host "  -> Total modules extraits                  : $totalModulesExtraits" -ForegroundColor Cyan

# ============================================================
# ETAPE 4 : SAUVEGARDE - Fichier JSON detaille centralise
# DETAILED_DATA_EXTRACT_SCA_KPI_dd_YYYYMMDD_HHmmss.json
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ETAPE 4 : SAUVEGARDE DES FICHIERS DE SORTIE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$detailParNature = @()
foreach ($nat in $naturesConfig) {
    $nb = ($enrichedAppsDORA | Where-Object {
        $_.characteristicCriteria.natures -and
        ($_.characteristicCriteria.natures | Where-Object { $_.code -eq $nat.code }).Count -gt 0
    }).Count
    $detailParNature += [PSCustomObject]@{
        code       = $nat.code
        labelEn    = $nat.labelEn
        labelFr    = $nat.labelFr
        legacyCode = $nat.legacyCode
        count      = $nb
    }
}

$globalOutput = [PSCustomObject]@{

    MetaData = [PSCustomObject]@{
        DateExtraction   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ScriptVersion    = "2.0-unifie"
        CleUnique        = "cia"
        Description      = "Extraction complete DORA enrichie avec scans DSO360 SCA au niveau MODULE (interrogation directe par CIA)"

        ReglePerimetreDSO360 = [PSCustomObject]@{
            ScanOnlyListedNatures = $ScanOnlyListedNatures
            NatureCodesToScan     = $NatureCodesToScan
            Description           = if ($ScanOnlyListedNatures) {
                "DSO360 interroge uniquement pour les natures listees (comportement du script 1 original)"
            } else {
                "DSO360 interroge pour toutes les natures SAUF celles listees (comportement du texte 'Logique Unifiee')"
            }
        }

        TotalAppsDORA    = $enrichedAppsDORA.Count
        AppsAvecNature   = $appsWithNature
        AppsSansNature   = $appsWithoutNature
        DetailParNature  = $detailParNature

        AppsHorsPerimetreDSO360 = $appsIgnoreesNA
        AppsInterrogeesDSO360   = $appsTraitees
        AppsAvecModulesDSO360   = $appsAvecModules
        AppsNonExistantesDSO360 = $appsNonExistantes
        AppsErreurDSO360        = $appsErreur
        TotalModulesExtraits    = $totalModulesExtraits

        LegendeChamps = [PSCustomObject]@{
            DSO360_ScanExist            = "Oui / Non / N/A (hors perimetre)"
            DSO360_ScanStatus           = "Statut global consolide du scan (ou liste des statuts distincts si heterogenes) / N/A"
            DSO360_SCA_Globale_LastScan = "Date du scan le plus recent parmi tous les modules de l'application / N/A"
            NB_Modules                  = "Nombre de modules detectes pour l'application / N/A"
            Liste_Modules               = "Liste des noms de modules / [] si N/A"
            Modules                     = "Detail par module : NomModule, Version, Statut, DSO360_SCA_Module_Last"
            DSO360_TraitementApplique   = "true si l'application etait dans le perimetre d'interrogation DSO360"
            DSO360_ErrorMessage         = "Message d'erreur ou de non-existence le cas echeant"
        }
    }

    Applications = $enrichedAppsDORA
}

try {
    Save-JsonUTF8 -FilePath $outputPathJSON -Data $globalOutput

    Write-Host ""
    Write-Host "OK - Fichier JSON detaille sauvegarde :" -ForegroundColor Green
    Write-Host "     $((Resolve-Path $outputPathJSON).Path)" -ForegroundColor White
    Write-Host "     Taille    : $([math]::Round((Get-Item $outputPathJSON).Length / 1KB, 2)) KB" -ForegroundColor White
    Write-Host "     Encodage  : UTF-8 sans BOM" -ForegroundColor White
}
catch {
    Write-Warning "ERREUR lors de la sauvegarde JSON : $_"
}

# Export CSV a plat des modules (complement pratique pour Excel)
try {
    if ($tousLesModulesFlat.Count -gt 0) {
        $tousLesModulesFlat | Export-Csv -Path $outputPathCSV -NoTypeInformation -Encoding utf8 -Delimiter ";"
        Write-Host "OK - Fichier CSV modules sauvegarde :" -ForegroundColor Green
        Write-Host "     $((Resolve-Path $outputPathCSV).Path)" -ForegroundColor White
    }
    else {
        Write-Host "(Aucun module a exporter en CSV)" -ForegroundColor DarkYellow
    }
}
catch {
    Write-Warning "ERREUR lors de la sauvegarde CSV : $_"
}

# ============================================================
# RESUME FINAL
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  RESUME FINAL" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Date d'execution                       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  Cle unique                             : CIA" -ForegroundColor White
Write-Host ""
Write-Host "  [DORA - Perimetre complet]" -ForegroundColor Cyan
Write-Host "  Total applications DORA                : $($enrichedAppsDORA.Count)" -ForegroundColor White
foreach ($nat in $naturesConfig) {
    $nb = ($enrichedAppsDORA | Where-Object {
        $_.characteristicCriteria.natures -and
        ($_.characteristicCriteria.natures | Where-Object { $_.code -eq $nat.code }).Count -gt 0
    }).Count
    Write-Host "    [$($nat.code)] $($nat.labelEn) : $nb" -ForegroundColor White
}
Write-Host ""
Write-Host "  [DSO360 - Modules]" -ForegroundColor Cyan
Write-Host "  Apps hors perimetre DSO360 (N/A)       : $appsIgnoreesNA" -ForegroundColor White
Write-Host "  Apps interrogees dans DSO360            : $appsTraitees" -ForegroundColor White
Write-Host "  ... avec modules trouves (Succes)       : $appsAvecModules" -ForegroundColor Green
Write-Host "  ... non existantes dans DSO360           : $appsNonExistantes" -ForegroundColor DarkYellow
Write-Host "  ... en erreur technique                  : $appsErreur" -ForegroundColor Red
Write-Host "  Total modules extraits                   : $totalModulesExtraits" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [FICHIERS GENERES]" -ForegroundColor Cyan
Write-Host "  $outputPathJSON" -ForegroundColor Green
if ($tousLesModulesFlat.Count -gt 0) {
    Write-Host "  $outputPathCSV" -ForegroundColor Green
}
Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Script termine avec succes !" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Magenta
