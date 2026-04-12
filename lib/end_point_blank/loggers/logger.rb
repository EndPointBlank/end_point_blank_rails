module EndPointBlank
  module Loggers
    class Logger

      def self.info(message)
      end

      def self.debug(message)
        Writers::Writer.new(:debug).write(message: message)
      end

      def self.error(message)
        ::Rails.logger.error(message)
      end

      def self.warn(message)
        ::Rails.logger.warn(message)
      end

      def self.fatal(message)
        ::Rails.logger.fatal(message)
      end

      private
      def self.write(message:, level: )
        Writers::Writer.new(:info).write(message: message)
      end
    end
  end
end