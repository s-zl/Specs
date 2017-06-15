module Pod
  # Stores the information relative to the target used to cluster the targets
  # of the single Pods. The client targets will then depend on this one.
  #
  class AggregateTarget < Target
    # @return [TargetDefinition] the target definition of the Podfile that
    #         generated this target.
    attr_reader :target_definition

    # Product types where the product's frameworks must be embedded in a host target
    #
    EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES = [:app_extension, :framework, :static_library, :messages_extension, :watch_extension, :xpc_service].freeze

    # Initialize a new instance
    #
    # @param [TargetDefinition] target_definition @see target_definition
    # @param [Sandbox] sandbox @see sandbox
    #
    def initialize(target_definition, sandbox)
      raise "Can't initialize an AggregateTarget with an abstract TargetDefinition" if target_definition.abstract?
      super()
      @target_definition = target_definition
      @sandbox = sandbox
      @pod_targets = []
      @search_paths_aggregate_targets = []
      @file_accessors = []
      @xcconfigs = {}
    end

    # @return [Boolean] True if the user_target refers to a
    #         library (framework, static or dynamic lib).
    #
    def library?
      # Without a user_project, we can't say for sure
      # that this is a library
      return false if user_project.nil?
      symbol_types = user_targets.map(&:symbol_type).uniq
      raise ArgumentError, "Expected single kind of user_target for #{name}. Found #{symbol_types.join(', ')}." unless symbol_types.count == 1
      [:framework, :dynamic_library, :static_library].include? symbol_types.first
    end

    # @return [Boolean] True if the user_target's pods are
    #         for an extension and must be embedded in a host,
    #         target, otherwise false.
    #
    def requires_host_target?
      # If we don't have a user_project, then we can't
      # glean any info about how this target is going to
      # be integrated, so return false since we can't know
      # for sure that this target refers to an extension
      # target that would require a host target
      return false if user_project.nil?
      symbol_types = user_targets.map(&:symbol_type).uniq
      raise ArgumentError, "Expected single kind of user_target for #{name}. Found #{symbol_types.join(', ')}." unless symbol_types.count == 1
      EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES.include?(symbol_types[0])
    end

    # @return [String] the label for the target.
    #
    def label
      target_definition.label.to_s
    end

    # @return [String] the name to use for the source code module constructed
    #         for this target, and which will be used to import the module in
    #         implementation source files.
    #
    def product_module_name
      c99ext_identifier(label)
    end

    # @return [Platform] the platform for this target.
    #
    def platform
      @platform ||= target_definition.platform
    end

    # @return [Podfile] The podfile which declares the dependency
    #
    def podfile
      target_definition.podfile
    end

    # @return [Pathname] the folder where the client is stored used for
    #         computing the relative paths. If integrating it should be the
    #         folder where the user project is stored, otherwise it should
    #         be the installation root.
    #
    attr_accessor :client_root

    # @return [Xcodeproj::Project] the user project that this target will
    #         integrate as identified by the analyzer.
    #
    attr_accessor :user_project

    # @return [Pathname] the path of the user project that this target will
    #         integrate as identified by the analyzer.
    #
    def user_project_path
      user_project.path if user_project
    end

    # @return [Array<String>] the list of the UUIDs of the user targets that
    #         will be integrated by this target as identified by the analyzer.
    #
    # @note   The target instances are not stored to prevent editing different
    #         instances.
    #
    attr_accessor :user_target_uuids

    # List all user targets that will be integrated by this #target.
    #
    # @return [Array<PBXNativeTarget>]
    #
    def user_targets
      return [] unless user_project
      user_target_uuids.map do |uuid|
        native_target = user_project.objects_by_uuid[uuid]
        unless native_target
          raise Informative, '[Bug] Unable to find the target with ' \
            "the `#{uuid}` UUID for the `#{self}` integration library"
        end
        native_target
      end
    end

    # @return [Hash<String, Xcodeproj::Config>] Map from configuration name to
    #         configuration file for the target
    #
    # @note   The configurations are generated by the {TargetInstaller} and
    #         used by {UserProjectIntegrator} to check for any overridden
    #         values.
    #
    attr_reader :xcconfigs

    # @return [Array<PodTarget>] The dependencies for this target.
    #
    attr_accessor :pod_targets

    # @return [Array<AggregateTarget>] The aggregate targets whose pods this
    #         target must be able to import, but will not directly link against.
    #
    attr_accessor :search_paths_aggregate_targets

    # @param  [String] build_configuration The build configuration for which the
    #         the pod targets should be returned.
    #
    # @return [Array<PodTarget>] the pod targets for the given build
    #         configuration.
    #
    def pod_targets_for_build_configuration(build_configuration)
      pod_targets.select do |pod_target|
        pod_target.include_in_build_config?(target_definition, build_configuration)
      end
    end

    # @return [Array<Specification>] The specifications used by this aggregate target.
    #
    def specs
      pod_targets.map(&:specs).flatten
    end

    # @return [Hash{Symbol => Array<Specification>}] The pod targets for each
    #         build configuration.
    #
    def specs_by_build_configuration
      result = {}
      user_build_configurations.keys.each do |build_configuration|
        result[build_configuration] = pod_targets_for_build_configuration(build_configuration).
          flat_map(&:specs)
      end
      result
    end

    # @return [Array<Specification::Consumer>] The consumers of the Pod.
    #
    def spec_consumers
      specs.map { |spec| spec.consumer(platform) }
    end

    # @return [Boolean] Whether the target uses Swift code
    #
    def uses_swift?
      pod_targets.any?(&:uses_swift?)
    end

    # @return [Hash{ Hash{ Symbol => String}}] The vendored dynamic artifacts and framework targets grouped by config
    #
    def frameworks_by_config
      frameworks_by_config = {}
      user_build_configurations.keys.each do |config|
        relevant_pod_targets = pod_targets.select do |pod_target|
          pod_target.include_in_build_config?(target_definition, config)
        end
        frameworks_by_config[config] = relevant_pod_targets.flat_map do |pod_target|
          frameworks = pod_target.file_accessors.flat_map(&:vendored_dynamic_artifacts).map do |fw|
            relative_path_to_sandbox = fw.relative_path_from(sandbox.root)
            relative_path_to_pods_root = "${PODS_ROOT}/#{relative_path_to_sandbox}"
            install_path = "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/#{fw.basename}"
            result = {
              :framework => relative_path_to_pods_root,
              :install_path => install_path,
            }
            # Until this can be configured, assume the dSYM file uses the file name as the framework.
            # See https://github.com/CocoaPods/CocoaPods/issues/1698
            dsym_path = Pathname.new("#{fw.dirname}/#{fw.basename}.dSYM")
            if dsym_path.exist?
              result[:dsym] = "#{relative_path_to_pods_root}.dSYM"
              result[:dsym_install_path] = "${DWARF_DSYM_FOLDER_PATH}/#{fw.basename}.dSYM"
            end
            result
          end
          # For non vendored frameworks Xcode will generate the dSYM and copy it instead.
          if pod_target.should_build? && pod_target.requires_frameworks?
            frameworks << { :framework => pod_target.build_product_path('${BUILT_PRODUCTS_DIR}'), :install_path => "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/#{pod_target.product_name}" }
          end
          frameworks
        end
      end
      frameworks_by_config
    end

    # @return [Hash{ Symbol => Array<Pathname> }] Uniqued Resources grouped by config
    #
    def resources_by_config
      library_targets = pod_targets.reject do |pod_target|
        pod_target.should_build? && pod_target.requires_frameworks?
      end
      user_build_configurations.keys.each_with_object({}) do |config, resources_by_config|
        resources_by_config[config] = library_targets.flat_map do |library_target|
          next [] unless library_target.include_in_build_config?(target_definition, config)
          resource_paths = library_target.file_accessors.flat_map do |accessor|
            accessor.resources.flat_map { |res| res.relative_path_from(sandbox.project.path.dirname) }
          end
          resource_bundles = library_target.file_accessors.flat_map do |accessor|
            accessor.resource_bundles.keys.map { |name| "#{library_target.configuration_build_dir}/#{name.shellescape}.bundle" }
          end
          (resource_paths + resource_bundles + [bridge_support_file].compact).uniq
        end
      end
    end

    # @return [Pathname] the path of the bridge support file relative to the
    #         sandbox or `nil` if bridge support is disabled.
    #
    def bridge_support_file
      bridge_support_path.relative_path_from(sandbox.root) if podfile.generate_bridge_support?
    end

    #-------------------------------------------------------------------------#

    # @!group Support files

    # @return [Pathname] The absolute path of acknowledgements file.
    #
    # @note   The acknowledgements generators add the extension according to
    #         the file type.
    #
    def acknowledgements_basepath
      support_files_dir + "#{label}-acknowledgements"
    end

    # @return [Pathname] The absolute path of the copy resources script.
    #
    def copy_resources_script_path
      support_files_dir + "#{label}-resources.sh"
    end

    # @return [Pathname] The absolute path of the embed frameworks script.
    #
    def embed_frameworks_script_path
      support_files_dir + "#{label}-frameworks.sh"
    end

    # @return [String] The output file path fo the check manifest lock script.
    #
    def check_manifest_lock_script_output_file_path
      "$(DERIVED_FILE_DIR)/#{label}-checkManifestLockResult.txt"
    end

    # @return [String] The xcconfig path of the root from the `$(SRCROOT)`
    #         variable of the user's project.
    #
    def relative_pods_root
      "${SRCROOT}/#{sandbox.root.relative_path_from(client_root)}"
    end

    # @return [String] The path of the Podfile directory relative to the
    #         root of the user project.
    #
    def podfile_dir_relative_path
      podfile_path = target_definition.podfile.defined_in_file
      return "${SRCROOT}/#{podfile_path.relative_path_from(client_root).dirname}" unless podfile_path.nil?
      # Fallback to the standard path if the Podfile is not represented by a file.
      '${PODS_ROOT}/..'
    end

    # @param  [String] config_name The build configuration name to get the xcconfig for
    # @return [String] The path of the xcconfig file relative to the root of
    #         the user project.
    #
    def xcconfig_relative_path(config_name)
      relative_to_srcroot(xcconfig_path(config_name)).to_s
    end

    # @return [String] The path of the copy resources script relative to the
    #         root of the user project.
    #
    def copy_resources_script_relative_path
      "${SRCROOT}/#{relative_to_srcroot(copy_resources_script_path)}"
    end

    # @return [String] The path of the embed frameworks relative to the
    #         root of the user project.
    #
    def embed_frameworks_script_relative_path
      "${SRCROOT}/#{relative_to_srcroot(embed_frameworks_script_path)}"
    end

    private

    # @!group Private Helpers
    #-------------------------------------------------------------------------#

    # Computes the relative path of a sandboxed file from the `$(SRCROOT)`
    # variable of the user's project.
    #
    # @param  [Pathname] path
    #         A relative path from the root of the sandbox.
    #
    # @return [String] The computed path.
    #
    def relative_to_srcroot(path)
      path.relative_path_from(client_root).to_s
    end
  end
end
