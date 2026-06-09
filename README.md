# EndPointBlankRack

TODO: Delete this and the text below, and describe your gem

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/end_point_blank_rack`. To experiment with that code, run `bin/console` for an interactive prompt.

## Installation

TODO: Replace `UPDATE_WITH_YOUR_GEM_NAME_PRIOR_TO_RELEASE_TO_RUBYGEMS_ORG` with your gem name right after releasing it to RubyGems.org. Please do not do it earlier due to security reasons. Alternatively, replace this section with instructions to install your gem from git if you don't plan to release to RubyGems.org.

Install the gem and add to the application's Gemfile by executing:

    $ bundle add UPDATE_WITH_YOUR_GEM_NAME_PRIOR_TO_RELEASE_TO_RUBYGEMS_ORG

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install UPDATE_WITH_YOUR_GEM_NAME_PRIOR_TO_RELEASE_TO_RUBYGEMS_ORG

## Usage

### Masking

Mask sensitive data **before it leaves your app**. Configure an ordered list of rules; each rule
targets one field and masks by a JSONPath, a regex, or both. (Server-side intake also masks
independently, so this is defense in depth.)

```ruby
EndPointBlank.configure do |config|
  config.masking_rules = [
    # Replace any "ssn" field at any depth in the request body.
    { target: "request_body", path: "$..ssn", replacement_value: "***" },
    # Keep first/last 4 of a card number in error messages via backreferences.
    { target: "error_message", regex: "(\\d{4})-\\d{4}-\\d{4}-(\\d{4})", replacement_value: "$1-****-****-$2" }
  ]
  # Optional: runs after the rules; last chance to transform the payload.
  config.mask_hook = ->(payload, record_type) { payload }
end
```

Rules are hashes with symbol keys.

**Rule fields**

- `target` — exactly one of `"request_body"`, `"request_headers"`, `"path"`, `"response_body"`, `"error_message"`.
- `path` — an optional JSONPath (supported subset: `$`, `.name`, `['name']`, `[n]`, `.*` / `[*]`,
  and `..name` for recursive descent). Keys are case-sensitive.
- `regex` — an optional regular expression.
- `replacement_value` — the replacement string (default `"..."`).

**Semantics — path scopes, regex matches within.** With only a `path`, the selected node is replaced
entirely. With only a `regex`, every matching string is replaced. With both, the regex is applied
only within the path-selected node(s). When a `regex` is present, `replacement_value` supports
backreferences: `$1`, `$2`, … insert capture groups (`$0` the whole match; `$$` for a literal `$`).
Stacktraces and log messages are never masked.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/end_point_blank_rack.
