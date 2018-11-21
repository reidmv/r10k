require 'r10k/git'
require 'r10k/environment'
require 'r10k/environment/name'

# This class implements a source for Git-based puppet-environments.
#
# A puppet-environments source generates environments by locally caching the given Git
# repository and enumerating the branches for the Git repository. Branches
# are mapped to environments without modification.
#
# @since 1.3.0
class R10K::Source::PuppetEnvironmentsRepo < R10K::Source::Git

  include R10K::Logging

  R10K::Source.register(:puppet_environments_repo, self)

  # @!attribute [r] branch
  #   @return [String] The branch to read environments from in the remote git repository
  attr_reader :branch

  # @!attribute [r] invalid_environments
  #   @return [String] How environment names that cannot be cleanly mapped to
  #     Puppet environments will be handled
  attr_reader :invalid_environments

  # Initialize the given source.
  #
  # @param name [String] The identifier for this source.
  # @param basedir [String] The base directory where the generated environments will be created.
  # @param options [Hash] An additional set of options for this source.
  #
  # @option options [Boolean, String] :prefix If a String this becomes the prefix.
  #   If true, will use the source name as the prefix.
  #   Defaults to false for no environment prefix.
  # @option options [String] :branch The branch to read environments from in the remote git
  #   repository.
  # @option options [Hash] :settings Additional settings that configure how the
  #   source should behave.
  def initialize(name, basedir, options = {})
    super

    @invalid_environments = (options[:invalid_environments] || 'correct_and_warn')
    @branch = (options[:branch] || 'HEAD')
  end

  # Re-define this method to overload debug log message
  #
  # @return [void]
  def preload!
    logger.debug _("Fetching '%{remote}' to determine current environment definitions.") % {remote: @remote}
    @cache.sync
  rescue => e
    raise R10K::Error.wrap(e, _("Unable to determine current environment definitions for Puppet Environment Repo source '%{name}' (%{basedir})") % {name: @name, basedir: @basedir})
  end

  def environments_config
    @environments_config ||= YAML.load(@cache.repo.cat_file('environments.yaml'))
  end

  def generate_environments
    envs = []

    # Create each of the static environments defined
    environment_tuples.each do |tuple|
      env = tuple_to_environment(tuple)
      envs << env unless env.nil?
    end

    # Generate dynamic environments if so configured
    dynamic_environment_tuples(envs).each do |tuple|
      env = tuple_to_environment(tuple)
      envs << env unless env.nil?
    end

    envs
  end

  def tuple_to_environment(tuple)
    data, env = tuple

    data['signature'] =  "#{env.name}.yaml:#{@cache.repo.resolve(@branch)}"

    if (data['base'].nil? || data['base']['source'].nil? || data['base']['ref'].nil?)
      logger.error _("Environment %{env_name} did not specify a valid base, ignoring it") % {env_name: env.name}
      return nil
    end

    remote = data['base']['source']
    ref    = data['base']['ref']

    if env.valid?
      R10K::Environment::Yaml.new(env.name, @basedir, env.dirname, {
        remote: remote, ref: ref, puppetfile_name: puppetfile_name, definition: data
      })
    elsif env.correct?
     logger.warn _("Environment %{env_name} contained non-word characters, correcting name to %{corrected_env_name}") % {env_name: env.name.inspect, corrected_env_name: env.dirname}
      R10K::Environment::Yaml.new(env.name, @basedir, env.dirname, {
        remote: remote, ref: ref, puppetfile_name: puppetfile_name, definition: data
      })
    elsif env.validate?
     logger.error _("Environment %{env_name} contained non-word characters, ignoring it.") % {env_name: env.name.inspect}
     nil
    end
  end

  def environment_tuples
    conf = YAML.load(@cache.repo.cat_file('environments.yaml'))
    envpath = conf['environmentspath'] || 'permanent:temporary'
    envpaths = envpath.split(':')

    filenames = envpaths.map do |envpath|
      @cache.repo.ls_files(@branch).select do |path|
        path =~ %r{^#{envpath}/[^/]*\.yaml$}
      end
    end.flatten

    opts = {prefix: @prefix, invalid: @invalid_environments, source: @name}

    filenames.map do |path|
      [ YAML.load(@cache.repo.cat_file(path, @branch)),
        R10K::Environment::Name.new(File.basename(path, '.yaml'), opts)
      ]
    end
  end

  def dynamic_environment_tuples(static_environments)
    return [] if environments_config['dynamic-environments'].nil?

    sources = environments_config['dynamic-environments'].map do |(name,hash)|
      hash['basedir'] ||= basedir
      R10K::Source.from_hash(name, hash)
    end.each do |dynsource|
      dynsource.preload!
    end

    environments = sources.map do |source|
      base_config = static_environments.find do |env|
        # TODO: investigate the weird Yaml symbol loading behavior in the last key
        env.name == environments_config['dynamic-environments'][source.name][:'use-modules-from']
      end.definition

      opts = {prefix: source.prefix, invalid: @invalid_environments, source: @name}
      source.environments.map do |env|
        definition = base_config.merge({
          'base' => {
            'source' => env.remote,
            'ref'    => env.ref
          }
        })
        
        [ definition,
          R10K::Environment::Name.new(env.name, opts)
        ]
      end
    end.flatten(1)
  end

end
