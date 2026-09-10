require "active_support/concern"

module EndPointBlank
  module Rails
    # Installs a `before_action :authenticate!` that asks intake whether the
    # calling credential may reach this controller at all, refusing the request
    # with an `UnauthorizedError` when it may not.
    #
    # == Why this concern exists rather than being deleted
    #
    # Until now it could not have worked once: it called
    # `EndPointBlank::Commands::EndpointAuthenticate`, a constant that has never
    # been defined anywhere in this gem, so every action of every controller
    # including it raised `NameError` before authentication could succeed or
    # fail. Nothing in this project included it, and the one test-application
    # controller named for it (`epb_test_rails`'s `AuthenticatedController`)
    # actually includes `Authorized`, so nothing ever noticed.
    #
    # That made "implement or delete" a real question. It is implemented,
    # because the authenticate path is not a Rails-only idea that Rails
    # happened not to need: the JS, Java and Python SDKs each expose one, and
    # each of their commands documents itself as "equivalent to the Ruby gem's
    # `EndPointBlank::Commands::BasicAuthenticate`". Three SDKs were ported
    # from a Ruby original that was here the whole time and simply never wired
    # up. (Elixir has no authenticate path at all, so "four other SDKs expose
    # one", as sc-306 puts it, is three -- but three of three name this gem.) A
    # missing authenticate path in Ruby is a gap, not a decision.
    #
    # == Why `BasicAuthenticate` and not a new `EndpointAuthenticate`
    #
    # Writing a `Commands::EndpointAuthenticate` to satisfy the old call site
    # would have invented a second command for a job this gem already has a
    # command for, and left `BasicAuthenticate` -- required by `end_point_blank.rb`,
    # ported into three other SDKs, and carrying the request body shape intake
    # actually reads -- dead in the tree next to it. Nothing can be depending on
    # the name `EndpointAuthenticate`, because it never resolved; no public
    # constant is being removed here, only one that was never there is being
    # left absent.
    #
    # == Deliberately no cache
    #
    # `Authorized` caches intake's answer per credential/route/method/version.
    # This path does not, matching every other SDK's authenticate command.
    # Adding one here would be a behaviour change none of the four share and
    # neither story asked for; it belongs in its own story if it is wanted.
    module Authenticated
      extend ActiveSupport::Concern

      included do
        before_action :authenticate!
      end

      def authenticate!
        result = EndPointBlank::Commands::BasicAuthenticate.authenticate(request)

        # The guard comes first, and reads `result` before anything is asked of
        # it. It used to run second: the body was parsed on the line above,
        # so `result.nil?` could never be reached -- a nil result raised
        # `NoMethodError` on nil instead of taking the branch written for it.
        # Fixing the missing constant alone would have exposed exactly that,
        # which is why both were fixed in one pass.
        return if result && result.status == 201

        # `raise UnauthorizedError.refusal_from(...)`, raising an instance,
        # rather than `raise UnauthorizedError, "message"`. The two-argument
        # `raise Class, message` form calls `Class.exception(message)` and can
        # pass nothing else, so it structurally could not carry intake's status
        # however willing `UnauthorizedError` was to accept one -- which is how
        # every refusal from this path was going to arrive as the class's 401
        # default, including the 403 that means "your credential is fine, you
        # have no grant for this endpoint".
        raise UnauthorizedError.refusal_from(result, "Authentication")
      end
    end
  end
end
