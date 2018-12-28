require 'r10k/logging'
require 'r10k/environment/git'
require 'forwardable'

# This class implements an environment based on a Git branch and Yaml definition.
class R10K::Environment::Yaml < R10K::Environment::Git

  # @!attribute [r] definition
  #   @return [Hash] The original definition used to create the environment
  attr_reader :definition

  # @!attribute [r] moduledir
  #   @return [String] The directory to install the modules #{basedir}/modules
  attr_reader :moduledir

  # @!attribute [r] environment_modules
  #   @return [Array] Modules being managed by the environment
  attr_reader :environment_modules

  # Initialize the given Environments Repo environment.
  #
  # @param name [String] The unique name describing this environment.
  # @param basedir [String] The base directory where this environment will be created.
  # @param dirname [String] The directory name for this environment.
  # @param options [Hash] An additional set of options for this environment.
  #
  # @option options [Hash] :definition The original hash that was used to define the
  #   environment.
  def initialize(name, basedir, dirname, options = {})
    super
    @remote = options[:remote]
    @ref    = options[:ref]
    @definition = options[:definition]
    @modules = []
    @managed_content = {}

    @modules_loaded = false

    @moduledir = @definition['moduledir'] || File.join(@basedir, @dirname, 'modules')
    @repo = R10K::Git::StatefulRepository.new(@remote, @basedir, @dirname)
  end

  def accept(visitor)
    visitor.visit(:environment, self) do
      self.load_modules
      @modules.each do |mod|
        mod.accept(visitor)
      end

      puppetfile.accept(visitor)
    end
  end

  def modules
    self.load_modules
    @modules + super
  end

  def signature
    "#{@definition['signature']},base:#{@repo.head}"
  end

  def load_modules
    return true if @modules_loaded

    unless @definition['modules'].nil?
      @definition['modules'].each do |name, args|
        add_module(name, args)
      end
    end

    validate_no_puppetfile_module_conflicts
    @modules_loaded = true
  end

  def validate_no_puppetfile_module_conflicts
    @puppetfile.load unless @puppetfile.loaded?
    conflicts = (@modules + @puppetfile.modules)
                .group_by { |mod| mod.name }
                .select { |_, v| v.size > 1 }
                .map(&:first)
    unless conflicts.empty?
      msg = _('Puppetfile cannot contain module names declared in %{envyaml}.') % {envyaml: environment.name + '.yaml'}
      msg += ' '
      msg += _("Remove the conflicting definitions of the following modules: %{conflicts}" % { conflicts: conflicts.join(' ') })
      raise R10K::Error.new(msg)
    end
  end

  # @param [String] name
  # @param [*Object] args
  def add_module(name, args)
    if args.is_a?(Hash)
      # symbolize keys in the args hash
      args = args.inject({}) { |memo,(k,v)| memo[k.to_sym] = v; memo }
    end

    if args.is_a?(Hash) && install_path = args.delete(:install_path)
      install_path = resolve_install_path(install_path)
      validate_install_path(install_path, name)
    else
      install_path = @moduledir
    end

    # Keep track of all the content this environment is managing to enable purging.
    @managed_content[install_path] = Array.new unless @managed_content.has_key?(install_path)

    mod = R10K::Module.new(name, install_path, args, self.name)
    mod.source = _('%{name}.yaml') % {name: self.name}

    @managed_content[install_path] << mod.name
    @modules << mod
  end

  def resolve_install_path(path)
    pn = Pathname.new(path)

    unless pn.absolute?
      pn = Pathname.new(File.join(basedir, path))
    end

    # .cleanpath is as good as we can do without touching the filesystem.
    # The .realpath methods will also choke if some of the intermediate
    # paths are missing, even though we will create them later as needed.
    pn.cleanpath.to_s
  end

  def environment_module_paths
    @managed_content.flat_map do |install_path, modnames|
      modnames.collect { |name| File.join(install_path, name) }
    end
  end

  def managed_directories
    self.load_modules

    super + @managed_content.keys
  end

  # Returns an array of the full paths to all the content being managed.
  # @note This implements a required method for the Purgeable mixin
  # @return [Array<String>]
  def desired_contents
    self.load_modules

    super + environment_module_paths
  end

  # Do not purge any files that are part of managed modules.
  def purge_exclusions
    self.load_modules

    exclusions = super
    exclusions += managed_directories
    exclusions += environment_module_paths.flat_map do |item|
      desired_tree = []

      if File.directory?(item)
        desired_tree << File.join(item, '**', '*')
      end

      Pathname.new(item).ascend do |path|
        break if path.to_s == @full_path
        desired_tree << path.to_s
      end

      desired_tree
    end

    exclusions
  end

end
