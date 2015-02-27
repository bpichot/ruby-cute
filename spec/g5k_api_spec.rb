require 'spec_helper'
# These tests can be executed either real or using mocking through WebMock
# Real tests can be activated by setting the shell variable TEST_REAL
describe Cute::G5K::API do

  subject { g5k = ENV['TEST_REAL'].nil?? Cute::G5K::API.new(:user => "test") : Cute::G5K::API.new() }


  let(:sites) { subject.site_uids}

  before :each do
    # Choosing a random site based on the date
    day = Time.now.day
    index = ((day/31.to_f)*sites.length).to_i
    index = 1 if index == 0
    @rand_site = sites[index]
    @env = subject.environment_uids(@rand_site).first
    if ENV['TEST_REAL']
      WebMock.disable!
      puts "Testing in real Grid'5000 using site: #{@rand_site}"
      puts "Warning G5K_USER environment variable has to be defined for some tests" if ENV['G5K_USER'].nil?
    end
  end

  it "checks initialization of G5K::API" do
    expect(subject.rest).to be_an_instance_of(Cute::G5K::G5KRest)
  end

  it "returns an array with the site ids" do
    expect(sites.length).to be > 0
  end

  it "returns an array with the clusters ids" do
    clusters = subject.cluster_uids(@rand_site)
    expect(clusters.length).to be > 0
  end

  it "returns a JSON Hash with the status of a site" do
    expect(subject.site_status(@rand_site)).to be_an_instance_of(Cute::G5K::G5KJSON)
  end

  it "returns a Hash with nodes status" do
    expect(subject.nodes_status(@rand_site)).to be_an_instance_of(Hash)
    expect(subject.nodes_status(@rand_site).length).to be > 0
  end

  it "returns an array with site status" do
    expect(subject.sites).to be_an_instance_of(Cute::G5K::G5KArray)
  end

  it "returns jobs in the site" do
    expect(subject.get_jobs(@rand_site)).to be_an_instance_of(Array)
  end

  it "return my_jobs in the site" do
    expect(subject.get_my_jobs(@rand_site)).to be_an_instance_of(Array)
  end

  it "returns all deployments" do
    expect(subject.get_deployments(@rand_site)).to be_an_instance_of(Cute::G5K::G5KArray)
  end

  it "raises a non found error" do
    expect{subject.get_jobs("non-found")}.to raise_error(Cute::G5K::NotFound)
  end

  it "raises a bad request error" do
    expect{ subject.reserve(:site => @rand_site, :resources =>"/slash_22=1+{non_sense}")}.to raise_error(Cute::G5K::BadRequest)
#    expect{ subject.reserve(:site => @rand_site, :resources =>"{ib30g='YES'}/nodes=2")}.to raise_error(Cute::G5K::BadRequest)
  end

  it "raises argument errors" do
    job = Cute::G5K::G5KJSON.new
    expect {subject.deploy(:env => "env")}.to raise_error(ArgumentError)
    expect {subject.deploy(job)}.to raise_error(ArgumentError)
    expect {subject.reserve(:non_existing => "site")}.to raise_error(ArgumentError)
  end

  it "raises invalid nodes format" do
    job = Cute::G5K::G5KJSON.new
    expect{subject.deploy(job,:env => "env")}.to raise_error(RuntimeError,"Unrecognized nodes format, use an Array")
  end

  it "raises error vlan" do
    expect {subject.reserve(:site => @rand_site, :vlan => :nonsense)}.to raise_error(ArgumentError,'Option for vlan not recognized')
  end


  it "reserves and returns a valid job" do
    job = subject.reserve(:site => @rand_site)
    expect(job).to be_an_instance_of(Cute::G5K::G5KJSON)
    subject.release(job)
  end


  it "reserves with vlan and get vlan hostnames" do
    job = subject.reserve(:site => @rand_site, :nodes => 1, :type => :deploy, :vlan => :routed)
    expect(subject.get_vlan_nodes(job)).to be_an_instance_of(Array)
    subject.release(job)
  end

  it "gets subnets from job" do
    job = subject.reserve(:site => @rand_site, :nodes => 1, :subnets => [22,2])
    expect(subject.get_subnets(job).first).to be_an_instance_of(IPAddress::IPv4)
    subject.release(job)
  end


  it "does not deploy immediately" do
    job = subject.reserve(:site => @rand_site, :type => :deploy )
    expect(job).to include("types" => ["deploy"])
    expect(job).to_not have_key("deploy")
  end

  it "tests deploy with keys option" do
    # Getting a deploy job
    job = subject.get_my_jobs(@rand_site).select{ |j| j.has_value?(["deploy"])}.first
    fake_key = Tempfile.new(["keys",".pub"])
    fake_key_path = fake_key.path.split(".pub").first
    expect(subject.deploy(job,:env => @env,:wait => true, :keys => fake_key_path)).to be_an_instance_of(Cute::G5K::G5KJSON)
    fake_key.delete
  end

  it "waits for a deploy" do
    job = subject.get_my_jobs(@rand_site).select{ |j| j.has_value?(["deploy"])}.first
    # It verifies that the job has been submitted with deploy
    expect(subject.deploy_status(job)).to be_an_instance_of(Array)
    subject.wait_for_deploy(job)
    expect(subject.deploy_status(job)).to be_an_instance_of(Array)

    #deploying again
    # subject.deploy(job, :env => @env)
    # subject.wait_for_deploy(job)
    # expect(subject.deploy_status(job).uniq).to eq(["terminated"])
  end


  it "submits a job and then deploy" do
    expect(subject.reserve(:site => @rand_site, :env => @env)).to have_key("deploy")
  end


  it "returns the same information" do
    #low level REST access
    jobs_running = subject.rest.get_json("sid/sites/#{@rand_site}/jobs/?state=running").items.length
    expect(subject.get_jobs(@rand_site,nil,"running").length).to eq(jobs_running)
  end

  it "submit and does not wait for the reservation" do
    cluster = subject.cluster_uids(@rand_site).first
    job = subject.reserve(:site => @rand_site, :wait => false)
    job = subject.wait_for_job(job, :wait_time => 600)
    expect(job).to include('state' => "running")
  end


  it "should submit a job with OAR hierarchy" do

   job1 = subject.reserve(:site => @rand_site, :switches => 2, :nodes=>1, :cpus => 1, :cores => 1,
                      :keys => "/home/#{ENV['G5K_USER']}/.ssh/id_rsa",:walltime => '00:10:00')
   job2 = subject.reserve(:site => @rand_site, :resources => "/switch=2/nodes=1/cpu=1/core=1",
                     :keys => "/home/#{ENV['G5K_USER']}/.ssh/id_rsa",:walltime => '00:10:00')

   expect(job1).to be_an_instance_of(Cute::G5K::G5KJSON)
   expect(job2).to be_an_instance_of(Cute::G5K::G5KJSON)

  end

  it "releases all jobs in a site" do
    expect(subject.release_all(@rand_site)).to be true
  end

end
