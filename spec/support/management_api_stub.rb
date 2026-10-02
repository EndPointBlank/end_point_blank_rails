# frozen_string_literal: true

require "json"
require "uri"

# Stubs the management API at Excon's own seam (Excon.stub with mock: true),
# so every spec runs the client's real request building, retrying and
# parsing. Each request is recorded; answers are taken from a queue, the last
# one repeating.
module ManagementApiStub
  KEY = "epb_mk_test_0123456789abcdef"
  BASE_URL = "https://portal.example.test"

  Request = Struct.new(:http_method, :path, :query, :headers, :body, keyword_init: true) do
    def header(name)
      headers.each { |key, value| return value if key.casecmp?(name) }
      nil
    end
  end

  def management_requests
    @management_requests ||= []
  end

  # Queues answers: each a Hash of status:, body: (a Hash is JSON-encoded),
  # headers:.
  def stub_management_api(*answers)
    queue = answers.empty? ? [{ status: 200, body: { data: {} } }] : answers.dup
    Excon.stub({}) do |params|
      management_requests << record(params)
      answer = queue.length > 1 ? queue.shift : queue.first
      raise answer[:raise] if answer[:raise]

      { status: answer.fetch(:status, 200), headers: answer.fetch(:headers, {}), body: encode(answer[:body]) }
    end
  end

  def management_client(**options)
    EndPointBlank::Management::Client.new(
      api_key: KEY, base_url: BASE_URL, excon_options: { mock: true }, sleeper: sleeps_recorder, **options
    )
  end

  def sleeps
    @sleeps ||= []
  end

  def sleeps_recorder
    ->(seconds) { sleeps << seconds }
  end

  def api_error(status, code, message = "refused", details: nil, headers: {})
    error = { code: code, message: message }
    error[:details] = details if details
    { status: status, body: { error: error }, headers: headers }
  end

  private

  def record(params)
    Request.new(
      http_method: params[:method].to_s.upcase,
      path: params[:path],
      query: params[:query].is_a?(String) ? URI.decode_www_form(params[:query]).to_h : (params[:query] || {}),
      headers: params[:headers] || {},
      body: params[:body].nil? || params[:body].empty? ? nil : JSON.parse(params[:body])
    )
  end

  def encode(body)
    case body
    when nil then ""
    when String then body
    else JSON.generate(body)
    end
  end
end

RSpec.configure do |config|
  config.include ManagementApiStub, :management_api
  config.after(:each, :management_api) do
    Excon.stubs.clear
    EndPointBlank::Management.reset_configuration!
  end
end
