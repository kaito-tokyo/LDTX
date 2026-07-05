#!/usr/bin/ruby
# frozen_string_literal: true

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

GITHUB_API_VERSION = '2022-11-28'
GITHUB_REPOSITORY = 'kaito-tokyo/LDTX'
GITHUB_WORKFLOW_FILE = 'release.yml'
INSTALLATION_TOKEN_URL =
  "https://api.github.com/app/installations/#{ENV.fetch('GH_APP_INSTALLATION_ID')}/access_tokens"
WORKFLOW_DISPATCH_URL =
  "https://api.github.com/repos/#{GITHUB_REPOSITORY}/actions/workflows/#{GITHUB_WORKFLOW_FILE}/dispatches"

def base64url(data)
  Base64.urlsafe_encode64(data).delete('=')
end

def github_app_private_key
  OpenSSL::PKey.read(Base64.decode64(ENV.fetch('GH_APP_PRIVATE_KEY_BASE64')))
end

def github_app_payload
  issued_at = Time.now.to_i - 60
  { iat: issued_at, exp: issued_at + 540, iss: ENV.fetch('GH_APP_ID') }
end

def github_app_jwt
  header = { alg: 'RS256', typ: 'JWT' }
  signing_input = [base64url(header.to_json), base64url(github_app_payload.to_json)].join('.')
  signature = github_app_private_key.sign(OpenSSL::Digest.new('SHA256'), signing_input)

  [signing_input, base64url(signature)].join('.')
end

def post_json(uri, headers:, body: nil)
  request = Net::HTTP::Post.new(uri)
  headers.each { |key, value| request[key] = value }
  request.body = body if body

  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
end

def github_headers(token)
  {
    'Accept' => 'application/vnd.github+json',
    'Authorization' => "Bearer #{token}",
    'X-GitHub-Api-Version' => GITHUB_API_VERSION
  }
end

def fetch_installation_token
  uri = URI(INSTALLATION_TOKEN_URL)
  response = post_json(uri, headers: github_headers(github_app_jwt))
  raise "POST #{uri} failed with #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body).fetch('token')
end

def xcode_cloud_inputs
  {
    xcode_cloud_build_id: ENV.fetch('CI_BUILD_ID')
  }
end

def dispatch_payload
  JSON.generate(ref: ENV.fetch('CI_TAG'), inputs: xcode_cloud_inputs)
end

def dispatch_workflow(installation_token)
  uri = URI(WORKFLOW_DISPATCH_URL)
  headers = github_headers(installation_token).merge('Content-Type' => 'application/json')
  response = post_json(uri, headers: headers, body: dispatch_payload)

  raise "POST #{uri} failed with #{response.code}: #{response.body}" unless response.code == '204'
end

dispatch_workflow(fetch_installation_token)
puts "Dispatched #{GITHUB_WORKFLOW_FILE} at #{ENV.fetch('CI_TAG')} for Xcode Cloud build #{ENV.fetch('CI_BUILD_ID')}."
