require 'restclient'
require 'yaml'
require 'json'
require 'pry'

module Cute

  class G5KArray < Array

    def uids
      return self.map { |it| it['uid'] }
    end

    def __repr__
      return self.map { |it| it.__repr__ }.to_s
    end

  end

  # Provides an abstraction for handling G5K responses
  # @see https://api.grid5000.fr/doc/3.0/reference/grid5000-media-types.html
  class G5KJson < Hash

    def items
      return self['items']
    end

    def nodes
      return self['nodes']
    end

    def rel(r)
      return self['links'].detect { |x| x['rel'] == r }['href']
    end

    def rel_self
      return rel('self')
    end

    def __repr__
      return self['uid'] unless self['uid'].nil?
      return Hash[self.map { |k, v| [k, v.__repr__ ] }].to_s
    end

    def refresh(g5k)
      return g5k.get_json(rel_self)
    end

    def self.parse(s)
      return JSON.parse(s, :object_class => G5KJson, :array_class => G5KArray)
    end


  end

  # Manages the low level operations for communicating with the REST API.
  class G5KRest

    attr_reader :user, :api
    API_VERSION = "sid"
    # Initializes a REST connection
    # @param uri [String] resource identifier which normally is the url of the Rest API
    # @param user [String] user if authentication is needed
    # @param pass [String] password if authentication is needed
    def initialize(uri,user=nil,pass=nil)
      @user = user
      @pass = pass
      if (user.nil? or pass.nil?)
        @endpoint = uri # Inside Grid'5000
      else
        user_escaped = CGI.escape(user)
        pass_escaped = CGI.escape(pass)
        @endpoint = "https://#{user_escaped}:#{pass_escaped}@#{uri.split("https://")[1]}"
      end
      @api = RestClient::Resource.new(@endpoint, :timeout => 15)
      test_connection
    end

    # Returns a resource object
    # @param path [String] this complements the URI to address to a specific resource
    def resource(path)
      path = path[1..-1] if path.start_with?('/')
      return @api[path]
    end

    # Returns the HTTP response as a Ruby Hash
    # @param path [String] this complements the URI to address to a specific resource
    def get_json(path)
      maxfails = 3
      fails = 0
      while true
        begin
          r = resource(path).get()
          return G5KJson.parse(r)
        rescue RestClient::RequestTimeout
          fails += 1
          raise if fails > maxfails
          Kernel.sleep(1.0)
        end
      end
    end

    # Creates a resource on the server
    # @param path [String] this complements the URI to address to a specific resource
    # @param json [Hash] contains the characteristics of the resources to be created.
    def post_json(path, json)
      r = resource(path).post(json.to_json,
                              :content_type => "application/json",
                              :accept => "application/json")
      return G5KJson.parse(r)
    end

    # Delete a resource on the server
    # @param path [String] this complements the URI to address to a specific resource
    def delete_json(path)
      begin
        return resource(path).delete()
      rescue RestClient::InternalServerError => e
        raise
      end
    end
    private

    # Test the connection and raises an error in case of a problem
    def test_connection
      begin
        return get_json("/#{API_VERSION}/")
        rescue RestClient::Unauthorized
          raise "Your Grid'5000 credentials are not recognized"
      end
    end

  end

  # Implements high level functions to get status information form Grid'5000 and
  # performs operations such as submitting jobs in the platform and deploying system images.
  class G5KUser

    API_VERSION = "sid"
    # Initializes a REST connection for Grid'5000 API
    # @param uri [String] resource identifier which normally is the url of the Rest API
    # @param user [String] user if authentication is needed
    # @param pass [String] password if authentication is needed
    def initialize(uri,user=nil,pass=nil)
      @user = user
      @pass = pass
      @g5k_connection = G5KRest.new(uri,user,pass)
    end

    # @return [String] Grid'5000 user
    def g5k_user
      return @user.nil? ? ENV['USER'] : @user
    end

    # @return [Array] all site identifiers
    def site_uids
      return sites.uids
    end

    # @return [Array] cluster identifiers
    def cluster_uids(site)
      return clusters(site).uids
    end

    # @return [Hash] all the status information of a given Grid'5000 site
    # @param site [String] a valid Grid'5000 site name
    def site_status(site)
      @g5k_connection.get_json(api_uri("sites/#{site}/status"))
    end

    # @return [Hash] the nodes state (e.g, free, busy, etc) that belong to a given Grid'5000 site
    # @param site [String] a valid Grid'5000 site name
    def get_nodes_status(site)
      nodes = {}
      site_status(site).nodes.each do |node|
        name = node[0]
        status = node[1]["soft"]
        nodes[name] = status
      end
      return nodes
    end

    # @return [Array] the description of all Grid'5000 sites
    def sites
      @g5k_connection.get_json(api_uri("sites")).items
    end

    # @return [Array] the description of the clusters that belong to a given Grid'5000 site
    # @param site [String] a valid Grid'5000 site name
    def clusters(site)
      @g5k_connection.get_json(api_uri("sites/#{site}/clusters")).items
    end

    # @returns [Hash] all the jobs submitted in a given Grid'5000 site,
    #          if a uid is provided only the jobs owned by the user are shown.
    # @param site [String] a valid Grid'5000 site name
    # @param uid [String] user name in Grid'5000
    def get_jobs(site, uid = nil, state)
      filter = uid.nil? ? "" : "&user=#{uid}"
      @g5k_connection.get_json(api_uri("/sites/#{site}/jobs/?state=#{state}#{filter}")).items
    end

    # @return [Hash] information concerning a given job submitted in a Grid'5000 site
    # @param site [String] a valid Grid'5000 site name
    # @param jid [Fixnum] a valid job identifier
    def get_job(site, jid)
      @g5k_connection.get_json(api_uri("/sites/#{site}/jobs/#{jid}"))
    end

    # @return [Hash] switches information available in a given Grid'5000 site.
    # @param site [String] a valid Grid'5000 site name
    def get_switches(site)
      items = @g5k_connection.get_json("/sites/#{site}/network_equipments").items
      items = items.select { |x| x['kind'] == 'switch' }
      # extract nodes connected to those switches
      items.each { |switch|
        conns = switch['linecards'].detect { |c| c['kind'] == 'node' }
        next if conns.nil?  # IB switches for example
        nodes = conns['ports'] \
          .select { |x| x != {} } \
          .map { |x| x['uid'] } \
          .map { |x| "#{x}.#{site}.grid5000.fr"}
        switch['nodes'] = nodes
      }
      return items.select { |it| it.key?('nodes') }
    end

    # @return [Hash] information of a specific switch available in a given Grid'5000 site.
    # @param site [String] a valid Grid'5000 site name
    # @param name [String] a valid switch name
    def get_switch(site, name)
      s = get_switches(site).detect { |x| x.uid == name }
      raise "Unknown switch '#{name}'" if s.nil?
      return s
    end

    # @returns [Array] all my jobs submitted to a given site
    # @param site [String] a valid Grid'5000 site name
    def my_jobs(site,state="running")
      return get_jobs(site, g5k_user,state)
    end

    # releases all jobs on a site
    def release_all(site)
      Timeout.timeout(20) do
        jobs = my_jobs(site)
        pass if jobs.length == 0
        begin
          jobs.each { |j| release(j) }
        rescue RestClient::InternalServerError => e
          raise unless e.response.include?('already killed')
        end
      end
    end

    # Release a resource
    def release(r)
      begin
        return @g5k_connection.delete_json(r.rel_self)
      rescue RestClient::InternalServerError => e
        raise unless e.response.include?('already killed')
      end
    end

    # @return a VLAN option codified to OAR.
    # @param opts [Hash]
    def handle_slash(opts)
      slash = nil
      predefined = { :slash_22 => 22, :slash_18 => 18 }
      if opts[:slash]
        bits = opts[:slash].to_i
        slash = "slash_#{bits}=1"
      else
        slashes = predefined.select { |label, bits| opts.key?(label) }
        unless slashes.empty?
          label, bits = slashes.first
          count = opts[label].to_i
          slash = "slash_#{bits}=#{count}"
        end
      end
      return slash
    end

    # helper for making the reservations the easy way
    # @param opts [Hash] options compatible with OAR
    def reserve_nodes(opts)

      nodes = opts.fetch(:nodes, 1)
      time = opts.fetch(:time, '01:00:00')
      at = opts[:at]
      slash = handle_slash(opts)
      site = opts[:site]
      type = opts.fetch(:type, :normal)
      keep = opts[:keep]
      name = opts.fetch(:name, 'rubyCute job')
      command = opts[:cmd]
      async = opts[:async]
      ignore_dead = opts[:ignore_dead]
      props = nil
      vlan = opts[:vlan]
      cluster = opts[:cluster]

      raise 'At least nodes, time and site must be given'  if [nodes, time, site].any? { |x| x.nil? }

      secs = time.to_secs
      time = time.to_time

      if nodes.is_a?(Array)
        all_nodes = nodes
        nodes = filter_dead_nodes(nodes) if ignore_dead
        removed_nodes = all_nodes - nodes
        info "Ignored nodes #{removed_nodes}." unless removed_nodes.empty?
        hosts = nodes.map { |n| "'#{n}'" }.sort.join(',')
        props = "host in (#{hosts})"
        nodes = nodes.length
      end

      raise 'Nodes must be an integer.' unless nodes.is_a?(Integer)
      # site = site.__repr__
      raise 'Type must be either :deploy or :normal' unless (type.respond_to?(:to_sym) && [ :normal, :deploy ].include?(type.to_sym))
      command = "sleep #{secs}" if command.nil?
      type = type.to_sym

      resources = "/nodes=#{nodes},walltime=#{time}"
      resources = "{cluster='#{cluster}'}" + resources unless cluster.nil?
      resources = "{type='kavlan'}/vlan=1+" + resources if vlan == true
      resources = "#{slash}+" + resources unless slash.nil?

      payload = {
                 'resources' => resources,
                 'name' => name,
                 'command' => command
                }

      info "Reserving resources: #{resources} (type: #{type}) (in #{site})"


      payload['properties'] = props unless props.nil?
      if type == :deploy
        payload['types'] = [ 'deploy' ]
      else
        payload['types'] = [ 'allow_classic_ssh' ]
      end

      unless at.nil?
        dt = parse_time(at)
        payload['reservation'] = dt
        info "Starting this reservation at #{dt}"
      end

      begin
        r = @g5k_connection.post_json(api_uri("sites/#{site}/jobs"),payload)  # This makes reference to the same class
      rescue => e
        info "Fail posting the json to the API"
        raise
      end

      # it may be a different thread that releases reservations
      # therefore we need to dereference proxy which
      # in fact uses Thread.current and is local to the thread...

      # I'm deactivating the code below because the engine method is
      # defined in an Activity

      # engine = proxy.engine

      # engine.on_finish do
      #   engine.verbose("Releasing job at #{r.rel_self}")
      #   release(r)
      # end if keep != true

      job = @g5k_connection.get_json(r.rel_self)
      job = wait_for_job(job) if async != true
      return job

    end

    # wait for the job to be in a running state
    # @param job [String] valid job identifier
    # @param wait_time [Fixnum] wait time before raising an exception, default 10h
    def wait_for_job(job,wait_time = 36000)

      jid = job
      info "Waiting for reservation #{jid}"
      Timeout.timeout(wait_time) do
        while true
          job = job.refresh(@g5k_connection)
          t = job['scheduled_at']
          if !t.nil?
            t = Time.at(t)
            secs = [ t - Time.now, 0 ].max.to_i
            info "Reservation #{jid} should be available at #{t} (#{secs} s)"
          end
          break if job['state'] == 'running'
          raise "Job is finishing." if job['state'] == 'finishing'
          Kernel.sleep(5)
        end
      end
      info "Reservation #{jid} ready"
      return job
    end

    private
    # Handle the output of messages within the module
    # @param msg [String] message to show
    def info(msg)
      if @logger.nil? then
        t = Time.now
        s = t.strftime('%Y-%m-%d %H:%M:%S.%L')
        puts "#{s} => #{msg}"
      end
    end

    # @returns a valid Grid'5000 resource
    # it avoids "//"
    def api_uri(path)
      path = path[1..-1] if path.start_with?('/')
      return "#{API_VERSION}/#{path}"
    end

  end

end
