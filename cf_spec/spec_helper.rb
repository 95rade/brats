require 'bundler/setup'
require 'fileutils'
require 'json'
require 'machete'
require 'machete/matchers'
require 'open-uri'
require 'yaml'
require 'shellwords'
require 'rspec/retry'

`mkdir -p log`
Machete.logger = Machete::Logger.new('log/integration.log')

def missing_buildpack_branch
  'Please specify a branch of the buildpack to run BRATS against. ' +
  "To do so, add '--tag buildpack_branch:<git branch>' to the arguments " +
  'passed to rspec'
end

RSpec.configure do |config|
  config.color = true
  config.tty = true
  config.verbose_retry = true
  config.default_retry_count = 3
  config.default_sleep_interval = 5
end

BUILDPACK_BRANCH = RSpec.configure do |config|
  branch = config.filter.rules[:buildpack_branch]
  raise missing_buildpack_branch if branch.nil?
  branch
end

def stack
  ENV["CF_STACK"] || 'cflinuxfs2'
end

def is_current_user_language_tag?(language)
  RSpec.configure do |config|
    language == config.filter.rules[:language]
  end
end

def parsed_manifest(buildpack:, branch: BUILDPACK_BRANCH)
  manifest_url = "https://raw.githubusercontent.com/cloudfoundry/#{buildpack}-buildpack/#{branch}/manifest.yml"
  YAML.load(open(manifest_url))
end

def sdk_msbuild?(sdk_version:, branch: BUILDPACK_BRANCH)
  sdk_versions_url = "https://raw.githubusercontent.com/cloudfoundry/dotnet-core-buildpack/#{branch}/dotnet-sdk-tools.yml"
  YAML.load(open(sdk_versions_url))['msbuild'].include? sdk_version
end

def dependency_versions_in_manifest(buildpack, dependency, stack)
  dependencies = parsed_manifest(buildpack: buildpack).fetch('dependencies')
  dependencies.select { |d| d['name'] == dependency && d['cf_stacks'].include?(stack) }.map {|dep| dep['version']}
end

def skip_if_no_dot_profile_support_on_targeted_cf
  minimum_acceptable_cf_api_version = '2.57.0'
  skip_reason = ".profile script functionality not supported before CF API version #{minimum_acceptable_cf_api_version}"
  Machete::RSpecHelpers.skip_if_cf_api_below(version: minimum_acceptable_cf_api_version, reason: skip_reason)
end

def add_dot_profile_script_to_app(template_path)
  profile_path = File.join(template_path, '.profile')
  File.open(profile_path, 'w') do |file|
    file.write( <<~BASHCODE
                   #!/usr/bin/env bash

                   echo PROFILE_SCRIPT_IS_PRESENT_AND_RAN

                   BASHCODE
)
    file.chmod(0755)
  end
end

def deploy_app(template:, stack:, buildpack:)
  buildpack.match /(.*)\-brat\-buildpack/
  language = $1
  ENV['BUILDPACK_VERSION'] = File.read("tmp/#{language}-buildpack/VERSION")

  Machete.deploy_app(
    template.path,
    name: template.name,
    buildpack: buildpack,
    stack: stack
  )
end

def bump_buildpack_version(buildpack:)
  FileUtils.mkdir_p('tmp')
  File.write("tmp/#{buildpack}-buildpack/VERSION", '99.99.99')
  Bundler.with_clean_env do
    if Dir.glob("tmp/#{buildpack}-buildpack/src/*/vendor/github.com/cloudfoundry/libbuildpack/packager/buildpack-packager").first
      system(<<-EOF)
             export GOPATH=$PWD/tmp/#{buildpack}-buildpack
             export GOBIN=$GOPATH/.bin
             (cd $GOPATH/src/*/vendor/github.com/cloudfoundry/libbuildpack/packager/buildpack-packager && go install)
             cd $GOPATH
             ./.bin/buildpack-packager --cached=true
             cf update-buildpack #{buildpack}-brat-buildpack -p #{buildpack}_buildpack-cached-v99.99.99.zip
             echo "\n\nBumping version of #{buildpack}-brat-buildpack\n\n"
      EOF
    else
      system(<<-EOF)
             cd tmp/#{buildpack}-buildpack
             export BUNDLE_GEMFILE=cf.Gemfile
             bundle install
             bundle exec buildpack-packager --cached
             cf update-buildpack #{buildpack}-brat-buildpack -p #{buildpack}_buildpack-cached-v99.99.99.zip
             echo "\n\nBumping version of #{buildpack}-brat-buildpack\n\n"
      EOF
    end
  end
end

def install_buildpack(buildpack:, branch: BUILDPACK_BRANCH, buildpack_caching: :cached, running_brats_suffix: '', &block)
  position = 100
  buildpack_caching = 'cached' unless buildpack_caching.to_s == 'uncached'

  FileUtils.mkdir_p('tmp')
  Bundler.with_clean_env do
    env = {
      'GITHUB_URL' => "https://github.com/cloudfoundry/#{buildpack}-buildpack",
      'BUNDLE_GEMFILE' => 'cf.Gemfile'
    }
    system(env, <<-EOF)
      set -e
      git clone -q -b #{branch} --depth 1 --recursive "$GITHUB_URL" tmp/#{buildpack}-buildpack
    EOF

    Dir.chdir("tmp/#{buildpack}-buildpack") do
      block.call if block

      if YAML.load_file('manifest.yml').keys.include?('include_files')
        system(env, <<-EOF) or raise "Could not install buildpack"
          set -ex
          export GOPATH=$PWD
          export GOBIN=$GOPATH/.bin
          (cd src/*/vendor/github.com/cloudfoundry/libbuildpack/packager/buildpack-packager && go install)
          ./.bin/buildpack-packager --cached=#{buildpack_caching.to_s == 'uncached' ? 'false' : 'true'}

          cf create-buildpack #{buildpack}-brat-buildpack $(ls *_buildpack*.zip | head -n 1) #{position} --enable

          echo "\n\nRunning Brats tests on: $GITHUB_URL\nUsing git branch: #{branch}\nLatest $(git log -1)\n\n"
        EOF
      else
        system(env, <<-EOF) or raise "Could not install buildpack"
          set -e
          bundle install
          bundle exec buildpack-packager --#{buildpack_caching} || bundle exec buildpack-packager #{buildpack_caching}
          cf create-buildpack #{buildpack}-brat-buildpack $(ls *_buildpack*.zip | head -n 1) #{position} --enable

          echo "\n\nRunning Brats tests on: $GITHUB_URL\nUsing git branch: #{branch}\nLatest $(git log -1)\n\n"
        EOF
      end
    end
  end
end

def install_buildpack_with_uri_credentials(buildpack:, branch: BUILDPACK_BRANCH, buildpack_caching: :uncached)
  install_buildpack(buildpack: buildpack, branch: branch, buildpack_caching: buildpack_caching, running_brats_suffix: ' simulated buildpack with credentials in uri') do
    manifest_path = "./manifest.yml"
    put_credentials_in_uris_in_manifest(manifest_path)
  end
end

def put_credentials_in_uris_in_manifest(manifest_path)
  manifest_hash = YAML.load_file(manifest_path)

  dependencies = manifest_hash["dependencies"]

  dependencies.each do |dep|
    next if dep['name'] == 'CAAPM'
    uri = URI(dep["uri"])
    uri.user = 'login'
    uri.password = 'password'
    dep["uri"] = uri.to_s
  end

  manifest_hash["dependencies"] = dependencies

  File.open(manifest_path, 'w') {|f| f.write(manifest_hash.to_yaml) }
end

def install_java_buildpack(branch: BUILDPACK_BRANCH, position: 100)
  FileUtils.mkdir_p('tmp')
  Bundler.with_clean_env do
    env = {
      'GITHUB_URL' => "https://github.com/cloudfoundry/java-buildpack",
      'BUNDLE_GEMFILE' => 'Gemfile'
    }
    system(env, <<-EOF)
      set -e
      GITHUB_URL=https://github.com/cloudfoundry/java-buildpack
      git clone -q -b #{branch} --depth 1 --recursive "$GITHUB_URL" tmp/java-buildpack
      cd tmp/java-buildpack
      bundle install
      bundle exec rake package OFFLINE=true PINNED=true
      cf delete-buildpack java-brat-buildpack -f
      cf create-buildpack java-brat-buildpack $(ls build/java-buildpack-offline-*.zip | head -n 1) #{position} --enable

      echo "\n\nRunning Brats tests on: $GITHUB_URL\nUsing git branch: #{branch}\nLatest $(git log -1)\n\n"
    EOF
  end
end

def cleanup_buildpack(buildpack:)
  `
    rm -Rf tmp/#{buildpack}-buildpack
    cf delete-buildpack #{buildpack}-brat-buildpack -f
  `
end

Dir['./cf_spec/support/**/*.rb'].each { |f| require f }
