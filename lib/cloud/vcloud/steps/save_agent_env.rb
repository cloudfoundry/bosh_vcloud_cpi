module VCloudCloud
  module Steps
    class SaveAgentEnv < Step
      def perform(metadata_key, action, networks, environment, &block)
        vapp = state[:vapp] = client.reload state[:vapp]
        vm = state[:vm] = client.reload state[:vm]
        metadata_link = "#{vm.metadata_link.href}/#{metadata_key}"
        
        env = if action == :update
          metadata = client.invoke :get, metadata_link
          Yajl.load(metadata.value || '{}')
        else
          system_disk = state[:disks][0]
          ephemeral_disk = get_newly_added_disk vm          
          {
            'vm' => { 'name' => vm.name, 'id' => vm.urn },
            'agent_id' => vm.name,
            'disks' => {
              'system' => system_disk.disk_id,
              'ephemeral' => ephemeral_disk.disk_id,
              'persistent' => {}              
            },
            'env' => environment || {}
          }
          # TODO env.merge!(@agent_properties)
        end

        env['networks'] = generate_network_env(vm.hardware_section.nics, networks) if networks

        @logger.debug "AGENT_ENV #{vm.urn} #{env.inspect}"
        
        env_json = Yajl::Encoder.encode env
        @logger.debug "ENV.ISO Content: #{env_json}"
        tmpdir = state[:tmpdir] = Dir.mktmpdir
        env_path = File.join tmpdir, 'env'
        iso_path = File.join tmpdir, 'env.iso'
        File.open(env_path, 'w') { |f| f.write env_json }
        output = `#{genisoimage} -o #{iso_path} #{env_path} 2>&1`
        @logger.debug "GENISOIMAGE #{output}"
        raise CloudError, "genisoimage: #{$?.exitstatus}: #{output}" unless $?.success?
        
        metadata = VCloudSdk::Xml::WrapperFactory.create_instance 'MetadataValue'
        metadata.value = env_json
        client.invoke_and_wait :put, metadata_link,
                  :payload => metadata,
                  :headers => { :content_type => VCloudSdk::Xml::MEDIA_TYPE[:METADATA_ITEM_VALUE] }
                  
        state[:iso] = iso_path
      end
      
      def cleanup
        FileUtils.remove_entry_secure state[:tmpdir] if state[:tmpdir]
      end
      
      private
      
      def genisoimage  # TODO: this should exist in bosh_common, eventually
        @genisoimage ||= Bosh::Common.which(%w{genisoimage mkisofs})
      end
    
      def get_newly_added_disk(vm)
        disks = vm.hardware_section.hard_disks
        newly_added = disks - state[:disks]
        if newly_added.size != 1
          #@logger.debug "Previous disks in #{vapp_id}: #{disks_previous.inspect}")
          #@logger.debug("Current disks in #{vapp_id}:  #{disks_current.inspect}")
          raise CloudError, "Expecting #{state[:disks].size + 1} disks, found #{disks.size}"
        end  
        newly_added[0]
      end
      
      def generate_network_env(nics, networks)
        nic_net = {}
        nics.each do |nic|
          nic_net[nic.network] = nic
        end
  
        network_env = {}
        networks.each do |network_name, network|
          network_entry = network.dup
          v_network_name = network['cloud_properties']['name']
          nic = nic_net[v_network_name]
          if nic.nil? then
            @logger.warn("Not generating network env for #{v_network_name}")
            next
          end
          network_entry['mac'] = nic.mac_address
          network_env[network_name] = network_entry
        end
        network_env
      end
    end
  end
end