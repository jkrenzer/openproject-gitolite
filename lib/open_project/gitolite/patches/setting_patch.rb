require 'fileutils'

module OpenProject::Gitolite
  module Patches
    module SettingPatch
      def self.included(base)
        base.class_eval do
          include InstanceMethods
          include OpenProject::Gitolite::GitoliteWrapper::RepositoriesHelper

          before_save :validate_settings
          after_commit :restore_revisions_git_values
          after_commit :fix_projects_without_settings
          after_commit :resync_all_ssh_keys_from_db
        end
      end

      module InstanceMethods
        private

        begin
          @@old_valuehash = Setting.plugin_openproject_gitolite.clone
        rescue
          @@old_valuehash = {}
        end

        @@resync_projects = false
        @@configure_projects = false
        @@resync_ssh_keys = false
        @@delete_trash_repo = []

        def validate_settings
          # Only validate settings for our plugin
          return unless name == 'plugin_openproject_gitolite'

          valuehash = value

          # Validate partials
          validate_server_names valuehash
          validate_gitolite_settings valuehash
          validate_git_config valuehash

          # Prepare any resync after sync
          prepare_resyncs valuehash

          # Prepare any configuration of settings
          prepare_configurations valuehash

          # Prepare any resync of ssh keys
          prepare_resync_all_ssh_keys valuehash

          # Save back results
          self.value = valuehash
        end

        def validate_server_names(valuehash)
          # Server domain should not include any path components. Also, ports should be numeric.
          [:https_server_domain, :ssh_server_domain, :http_server_domain].each do |setting|
            if valuehash[setting] && !valuehash[setting].empty?
              valuehash[setting] = valuehash[setting].lstrip.rstrip.split('/').first
            else
              valuehash[setting] = @@old_valuehash[setting]
            end
          end
        end

        def validate_gitolite_settings(valuehash)
          # Normalize paths, should be relative and end in '/'
          valuehash[:gitolite_global_storage_path] = File.join(valuehash[:gitolite_global_storage_path], '')

          # Validate ssh port > 0 and < 65537 (and exclude non-numbers)
          port = valuehash[:gitolite_server_port]
          if !port.to_i.between?(1, 65537)
            valuehash[:gitolite_server_port] = @@old_valuehash[:gitolite_server_port]
          end
        end

        def validate_git_config(valuehash)
          # Validate git author address
          if valuehash[:git_config_email].blank?
            valuehash[:git_config_email] = Setting.mail_from.to_s.strip.downcase
          elsif !/^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i.match(valuehash[:git_config_email])
            valuehash[:git_config_email] = @@old_valuehash[:git_config_email]
          end
        end

        def prepare_resyncs(valuehash)
          ## Rest force update requests
          @@resync_projects = valuehash[:gitolite_resync_all_projects] == 'true'
          valuehash[:gitolite_resync_all_projects] = 'false'
        end

        def prepare_configurations(valuehash)
          ## Rest configuration requests
          @@configure_projects = valuehash[:gitolite_configure_projects] == 'true'
          valuehash[:gitolite_configure_projects] = 'false'
        end

        def prepare_resync_all_ssh_keys(valuehash)
          ## Rest configuration requests
          @@resync_ssh_keys = valuehash[:gitolite_resync_all_ssh_keys] == 'true'
          valuehash[:gitolite_resync_all_ssh_keys] = 'false'
        end

        def restore_revisions_git_values
          # Only perform after-actions on settings for our plugin
          if name == 'plugin_openproject_gitolite'
            valuehash = value

            ## A resync has been asked within the interface, update all projects in force mode
            if @@resync_projects == true
              resync_projects
              @@resync_projects = false
            end

            @@old_valuehash = valuehash.clone
          end
        end

        def fix_projects_without_settings
          # Only perform after-actions on settings for our plugin
          if name == 'plugin_openproject_gitolite'
            valuehash = value

            ## A configuration of projects without proper settings has been asked within the interface, fix projects
            if @@configure_projects == true
              fix_project_settings
              @@configure_projects = false
            end

            @@old_valuehash = valuehash.clone
          end
        end

        def resync_all_ssh_keys_from_db
          # Only perform after-actions on settings for our plugin
          if name == 'plugin_openproject_gitolite'
            valuehash = value

            ## A resync of all public SSH keys has been asked within the interface, update all keys in force mode
            if @@resync_ssh_keys == true
              resync_all_ssh_keys
              @@resync_ssh_keys = false
            end

            @@old_valuehash = valuehash.clone
          end
        end

        def resync_projects
          # Makes sure that also the repositories in filesystem are in the right path
          resync_repos

          # Need to update everyone!
          projects = Project.active.includes(:repository).all
          if projects.length > 0
            OpenProject::Gitolite::GitoliteWrapper.logger.info(
              "Forced resync of all projects (#{projects.length})..."
            )
            OpenProject::Gitolite::GitoliteWrapper.update(:clear_gitolite_config, Project)
            OpenProject::Gitolite::GitoliteWrapper.update(:update_all_projects, projects.length)
          end
        end

        def fix_project_settings
          # Need to fix some projects!
          projects = Project.active.includes(:repository).all
          total_project_fixed = 0
          if projects.length > 0
            OpenProject::Gitolite::GitoliteWrapper.logger.info(
              "Forced configuration of projects. Analyzing #{projects.length} project(s) with Git repositories..."
            )

            projects.each do |project|
              next unless project.repository.is_a?(Repository::Gitolite)

              if project.repository.extra.nil?
                total_project_fixed += 1
                OpenProject::Gitolite::GitoliteWrapper.logger.info("Project #{project.name} not configured properly, generating configuration..." )
                project.repository.build_extra
                project.repository.extra.set_values_for_existing_repo
                project.repository.save
              end

            end
            OpenProject::Gitolite::GitoliteWrapper.logger.info(
              "Forced configuration of projects finished. A total of #{total_project_fixed} project(s) with errors were found and fixed."
            )


          end
        end

        def resync_all_ssh_keys
          # Need to update everyone!
          OpenProject::Gitolite::GitoliteWrapper.update(:update_all_ssh_keys_forced, GitolitePublicKey.all.length)
        end

        private

        def resync_repos
          OpenProject::Gitolite::GitoliteWrapper.logger.info("Resync of all repositories : Making sure all repositories are in proper place")
          projects_with_repos = Project.includes(:repository)
                                .where('repositories.type = ?', 'Repository::Gitolite')
                                .references('repositories')

          if projects_with_repos.size > 0
            projects_with_repos.each do |proj|
              gitolite_repos_root = OpenProject::Gitolite::GitoliteWrapper.gitolite_global_storage_path

              # Get the path (where the repo actually is) from the database in OpenProject
              old_path = URI.parse(proj.repository.url).path
              old_relative_path = Pathname.new(old_path).relative_path_from(Pathname.new(gitolite_repos_root))
              if File.dirname(old_path).to_s == gitolite_repos_root.to_s.chomp("/")
                old_name = File.basename(old_relative_path.to_s, '.git')
              else
                old_name = File.join(File.dirname(old_relative_path.to_s), File.basename(old_relative_path.to_s, '.git'))
              end

              # Build the path (where the repo should be) from the project's settings
              new_path  = proj.repository.managed_repository_path
              new_relative_path = Pathname.new(new_path).relative_path_from(Pathname.new(gitolite_repos_root))
              if File.dirname(new_path).to_s == gitolite_repos_root.to_s.chomp("/")
                new_name = File.basename(new_relative_path.to_s, '.git')
              else
                new_name = File.join(File.dirname(new_relative_path.to_s), File.basename(new_relative_path.to_s, '.git'))
              end

              if old_path == new_path
                # Nathing to do with this repository
                next
              end

              OpenProject::Gitolite::GitoliteWrapper.logger.warn("Resync of all repositories : Found repository '#{old_name}' in wrong location on filesystem")
              OpenProject::Gitolite::GitoliteWrapper.logger.warn("Resync of all repositories : Moving repository '#{old_name}' -> '#{new_name}' ")
              OpenProject::Gitolite::GitoliteWrapper.logger.debug("-- On filesystem, this means '#{old_path}' -> '#{new_path}'")

              if move_physical_repo(old_path, old_name, new_path, new_name, false)
                # Add the repo as new in Gitolite
                proj.repository.url = new_path
                proj.repository.root_url = new_path
                proj.repository.save
              end

            end
          end
        end

      end
    end
  end
end

Setting.send(:include, OpenProject::Gitolite::Patches::SettingPatch)
