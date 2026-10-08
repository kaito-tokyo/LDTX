# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function ConvertTo-Base64Url {
    param(
        [Parameter(ValueFromPipeline)]
        [object] $Value
    )

    process {
        if ($Value -is [string]) {
            $Value = [Text.Encoding]::UTF8.GetBytes($Value)
        }
        elseif ($Value -isnot [byte[]]) {
            throw 'Specify a string or byte array.'
        }
        [Convert]::ToBase64String($Value).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
}

function New-ES256SignedJwt {
    param(
        [Parameter(Mandatory)][hashtable] $Header,
        [Parameter(Mandatory)][hashtable] $Payload,
        [Parameter(Mandatory)][string] $PrivateKeyPem
    )

    $encodedHeader = ConvertTo-Json $Header -Compress | ConvertTo-Base64Url
    $encodedPayload = ConvertTo-Json $Payload -Compress | ConvertTo-Base64Url
    $signingInput = "$encodedHeader.$encodedPayload"
    $signingBytes = [Text.Encoding]::UTF8.GetBytes($signingInput)

    $key = [System.Security.Cryptography.ECDsa]::Create()

    try {
        $key.ImportFromPem($PrivateKeyPem)
        $curve = $key.ExportParameters($false).Curve
        $p256 = [System.Security.Cryptography.ECCurve+NamedCurves]::nistP256
        if ($curve.Oid.Value -ne $p256.Oid.Value) {
            throw 'ES256 requires a P-256 key.'
        }
    }
    catch {
        $key.Dispose()
        throw
    }

    try {
        $signature = $key.SignData(
            $signingBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
    }
    finally {
        $key.Dispose()
    }

    $encodedSignature = ConvertTo-Base64Url $signature
    "$signingInput.$encodedSignature"
}

function New-AppStoreConnectToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Issuer,
        [Parameter(Mandatory)][int] $ExpiresIn,
        [Parameter(Mandatory)][string] $KeyId,
        [Parameter(Mandatory)][string] $KeyBase64,
        [string[]] $Scope
    )

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $header = @{
        alg = 'ES256'
        kid = $KeyId
        typ = 'JWT'
    }

    $payload = @{
        iss = $Issuer
        iat = $now - 60
        exp = $now + [int]$ExpiresIn
        aud = 'appstoreconnect-v1'
    }

    if ($Scope) {
        $payload.scope = $Scope
    }

    $keyBytes = [Convert]::FromBase64String($KeyBase64)
    $pem = [Text.Encoding]::UTF8.GetString($keyBytes)
    New-ES256SignedJwt -Header $header -Payload $payload -PrivateKeyPem $pem
}

Export-ModuleMember -Function New-AppStoreConnectToken, New-ES256SignedJwt
