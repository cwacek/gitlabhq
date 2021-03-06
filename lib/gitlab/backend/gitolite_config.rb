require 'gitolite'
require 'timeout'
require 'fileutils'

module Gitlab
  class GitoliteConfig
    attr_reader :config_tmp_dir

    def reset_config_tmp_dir
      @config_tmp_dir = File.join(Rails.root, 'tmp',"gitlabhq-gitolite-#{Time.now.to_i}")
    end

    def apply
      Timeout::timeout(30) do
        File.open(File.join(Rails.root, 'tmp', "gitlabhq-gitolite.lock"), "w+") do |f|
          begin
            f.flock(File::LOCK_EX)
            reset_config_tmp_dir
            pull
            yield(self)
            push
            FileUtils.rm_rf(config_tmp_dir)
          ensure
            f.flock(File::LOCK_UN)
          end
        end
      end
    rescue Exception => ex
      Gitlab::Logger.error(ex.message)
      raise Gitolite::AccessDenied.new("gitolite timeout")
    end

    def destroy_project(project)
      FileUtils.rm_rf(project.path_to_repo)

      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(config_tmp_dir,'gitolite'))
      conf = ga_repo.config
      conf.rm_repo(project.path)
      ga_repo.save
    end

    def destroy_project!(project)
      apply do |config|
        config.destroy_project(project)
      end
    end

    def write_key(id, key)
      File.open(File.join(config_tmp_dir, 'gitolite/keydir',"#{id}.pub"), 'w') do |f|
        f.write(key.gsub(/\n/,''))
      end
    end

    def rm_key(user)
      File.unlink(File.join(config_tmp_dir, 'gitolite/keydir',"#{user}.pub"))
      `cd #{File.join(config_tmp_dir,'gitolite')} ; git rm keydir/#{user}.pub`
    end

    # update or create
    def update_project(repo_name, project)
      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(config_tmp_dir,'gitolite'))
      conf = ga_repo.config
      repo = update_project_config(project, conf)
      conf.add_repo(repo, true)

      ga_repo.save
    end

    def update_project!(repo_name, project)
      apply do |config|
        config.update_project(repo_name, project)
      end
    end

    # Updates many projects and uses project.path as the repo path
    # An order of magnitude faster than update_project
    def update_projects(projects)
      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(config_tmp_dir,'gitolite'))
      conf = ga_repo.config

      projects.each do |project|
        repo = update_project_config(project, conf)
        conf.add_repo(repo, true)
      end

      ga_repo.save
    end

    def update_project_config(project, conf)
      repo_name = project.path

      repo = if conf.has_repo?(repo_name)
               conf.get_repo(repo_name)
             else
               ::Gitolite::Config::Repo.new(repo_name)
             end

      name_readers = project.repository_readers
      name_writers = project.repository_writers
      name_masters = project.repository_masters

      pr_br = project.protected_branches.map(&:name).join("$ ")

      repo.clean_permissions

      # Deny access to protected branches for writers
      unless name_writers.blank? || pr_br.blank?
        repo.add_permission("-", pr_br.strip + "$ ", name_writers)
      end

      # Add read permissions
      repo.add_permission("R", "", name_readers) unless name_readers.blank?

      # Add write permissions
      repo.add_permission("RW+", "", name_writers) unless name_writers.blank?
      repo.add_permission("RW+", "", name_masters) unless name_masters.blank?

      repo
    end

    def admin_all_repo
      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(config_tmp_dir,'gitolite'))
      conf = ga_repo.config
      owner_name = ""

      # Read gitolite-admin user
      #
      begin
        repo = conf.get_repo("gitolite-admin")
        owner_name = repo.permissions[0]["RW+"][""][0]
        raise StandardError if owner_name.blank?
      rescue => ex
        puts "Can't determine gitolite-admin owner".red
        raise StandardError
      end

      # @ALL repos premission for gitolite owner
      repo_name = "@all"
      repo = if conf.has_repo?(repo_name)
               conf.get_repo(repo_name)
             else
               ::Gitolite::Config::Repo.new(repo_name)
             end

      repo.add_permission("RW+", "", owner_name)
      conf.add_repo(repo, true)
      ga_repo.save
    end

    def admin_all_repo!
      apply { |config| config.admin_all_repo }
    end

    private

    def pull
      Dir.mkdir config_tmp_dir
      `git clone #{Gitlab.config.gitolite_admin_uri} #{config_tmp_dir}/gitolite`
    end

    def push
      Dir.chdir(File.join(config_tmp_dir, "gitolite"))
      `git add -A`
      `git commit -am "GitLab"`
      `git push`
      Dir.chdir(Rails.root)
    end
  end
end

