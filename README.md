Buildpack Runtime Acceptance Tests
---

### Functionality

Test that the compiled binaries of the buildpacks are working as expected.

### Usage

Example of testing the Ruby buildpack:

```sh
mkdir -p ~/workspace
cd ~/workspace

git clone https://github.com/pivotal-cf/brats
cd ~/workspace/brats
bundle install

cf api api.cf-deployment.com

rspec cf_spec/integration/ruby_spec.rb --tag language:ruby
```

Note that the appropriate language tag is required to run the full BRATS suite for the specified buildpack.
The interpreter matrix tests will not execute unless the tag for the appropriate interpreter is passed into the rspec arguments.
