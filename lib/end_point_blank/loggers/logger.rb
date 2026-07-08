module EndPointBlank
  module Loggers
    class Logger

      def self.info(message)
      end

      def self.debug(message)
        Writers::Writer.new(:debug).write(message: message)
      end

      def self.error(message)
        EndPointBlank.logger.error(message)
      end

      def self.warn(message)
        EndPointBlank.logger.warn(message)
      end

      def self.fatal(message)
        EndPointBlank.logger.fatal(message)
      end

      private
      def self.write(message:, level: )
        Writers::Writer.new(:info).write(message: message)
      end
    end
  end
end