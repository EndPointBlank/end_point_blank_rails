module EndPointBlank
  class LogEntry
    attr_accessor :message, :stacktrace, :app, :status, :headers, :body, :env, :sent_at

    def initialize(message:, env: , stacktrace:, app:, status:, headers:, body:, sent_at: Time.now)
      @message = message
      @env = env
      @stacktrace = stacktrace
      @app = app
      @status = status
      @headers = headers
      @body = body
      @sent_at = sent_at
    end
  end
end