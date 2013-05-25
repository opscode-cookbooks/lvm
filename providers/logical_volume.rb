def initialize *args
    super
    require 'lvm'
    require 'mixlib/shellout'
end

def to_dm_name name
    #The device mapper will double any hyphens found in a volume group or
    #logical volume name so that it can properly locate the separator between
    #the volume group and the logical volume in the device name.
    name.gsub /-/, '--'
end

action :create do
    device_name = "/dev/mapper/#{to_dm_name(new_resource.group)}-#{to_dm_name(new_resource.name)}"
    fs_type = new_resource.filesystem

    ruby_block "resize physical volumes for lv #{new_resource.name}" do
      lvm = LVM::LVM.new
      block do
        lvm.physical_volumes.each { |pv|
          Chef::Log.debug "Resizing physical volume #{pv.name}"
          lvm.raw "pvresize #{pv.name}"
        }
      end
      not_if do
        lvm = LVM::LVM.new
        lvm.physical_volumes.nil? or not new_resource.resize
      end
    end

    ruby_block "extend_logical_volume_#{new_resource.name}" do
      block do
        lvm = LVM::LVM.new

        vg = lvm.volume_groups[new_resource.group]
        if vg.nil?
          Chef::Application.fatal!("Error volume group #{new_resource.group} does not exist", 2 )
        else
          lv = vg.logical_volumes.select do |lvs|
            lvs.name == new_resource.name
          end
          Chef::Application.fatal!("Error logical volume #{new_resource.name} does not exist", 2 ) if lv.empty?
        end

        lv = lv.first
        pe_size = lvm.volume_groups[new_resource.group].extent_size.to_i
        pe_free = lvm.volume_groups[new_resource.group].free_count.to_i
        lv_size_cur = lv.size.to_i / pe_size

        group = new_resource.group

        lv_size_req = case new_resource.size
                        when /(\d+)k/
                          ($1.to_i *1024) / pe_size
                        when /(\d+)K/
                          ($1.to_i * 1000) / pe_size
                        when /(\d+)m/
                          ($1.to_i * 1048576) / pe_size
                        when /(\d+)M/
                          ($1.to_i * 1000000) / pe_size
                        when /(\d+)g/
                          ($1.to_i * 1073741824) / pe_size
                        when /(\d+)G/
                          ($1.to_i * 1000000000) / pe_size
                        when /(\d+)t/
                          ($1.to_i * 1099511627776) / pe_size
                        when /(\d+)T/
                          ($1.to_i * 1000000000000) / pe_size
                        when /(\d+)/
                          $1.to_i
                      end

        Chef::Log.debug "Resizing logical volume #{lv.name} from #{lv_size_cur} pe to #{lv_size_req} pe with #{pe_free} pe left in volume group #{group}"

        Chef::Application.fatal!("Error trying to extend logical volume #{lv.name} beyond the capacity of volume group #{group}", 2 ) if ( lv_size_req - lv_size_cur ) > pe_free

        if lv_size_cur >= lv_size_req

          Chef::Log.debug "Logical volume #{lv.name} in volume group #{group} already at requested size"

        else

          resize_fs = "--resizefs"
          stripes = new_resource.stripes ? "--stripes #{new_resource.stripes}" : ''
          stripe_size = new_resource.stripe_size ? "--stripesize #{new_resource.stripe_size}" : ''
          mirrors = new_resource.mirrors ? "--mirrors #{new_resource.mirrors}" : ''

          command = "lvextend -l #{lv_size_req} #{resize_fs} #{stripes} #{stripe_size} #{mirrors} #{lv.path} "
          Chef::Log.debug "Running command: #{command}"
          output = lvm.raw command
          Chef::Log.debug "Command output: #{output}"

          new_resource.updated_by_last_action true

        end
      end
      not_if do
        lvm = LVM::LVM.new
        vg = lvm.volume_groups[new_resource.group]
        if vg.nil?
          true
        else
          found_lvs = vg.logical_volumes.select do |lv|
            lv.name == new_resource.name
          end
          found_lvs.empty? or not new_resource.resize
        end
      end
    end

    ruby_block "create_logical_volume_#{new_resource.name}" do
        block do 
            lvm = LVM::LVM.new

            name = new_resource.name
            group = new_resource.group
            size = case new_resource.size
                when /\d+[kKmMgGtT]/
                    "-L #{new_resource.size}"
                when /(\d{2}|100)%(FREE|VG|PVS)/
                    "-l #{new_resource.size}"
                when /(\d+)/
                    "-l #{$1}"
            end
            
            stripes = new_resource.stripes ? "--stripes #{new_resource.stripes}" : ''
            stripe_size = new_resource.stripe_size ? "--stripesize #{new_resource.stripe_size}" : ''
            mirrors = new_resource.mirrors ? "--mirrors #{new_resource.mirrors}" : ''
            contiguous = new_resource.contiguous ? "--contiguous y" : ''
            readahead = new_resource.readahead ? "--readahead #{new_resource.readahead}" : ''

            physical_volumes = [new_resource.physical_volumes].flatten.join ' ' if new_resource.physical_volumes
            
            command = "lvcreate #{size} #{stripes} #{stripe_size} #{mirrors} #{contiguous} #{readahead} --name #{name} #{group} #{physical_volumes}"

            Chef::Log.debug "Executing lvm command: #{command}"
            output = lvm.raw command 
            Chef::Log.debug "Command output: #{output}"
            new_resource.updated_by_last_action true
        end

        only_if do
            lvm = LVM::LVM.new
            vg = lvm.volume_groups[new_resource.group]
            if vg.nil?
              true
            else
              found_lvs = vg.logical_volumes.select do |lv|
                lv.name == new_resource.name
              end
              found_lvs.empty?
            end
        end
    end

    execute "format_logical_volume_#{new_resource.group}_#{new_resource.name}" do
        command "yes | mkfs -t #{fs_type} #{device_name}"
        not_if do
            if fs_type.nil?
              true
            else
              Chef::Log.debug "Checking to see if #{device_name} is formatted..."
              blkid = ::Mixlib::ShellOut.new "blkid -o value -s TYPE #{device_name}"
              blkid.run_command

              Chef::Log.debug "Result of check: #{blkid}"
              Chef::Log.debug "blkid.exitstatus: #{blkid.exitstatus}"
              Chef::Log.debug "blkid.stdout: #{blkid.stdout.inspect}"
              blkid.exitstatus == 0 && blkid.stdout.strip == fs_type.strip
            end
        end 
    end

    if new_resource.mount_point
        if new_resource.mount_point.class == String
            mount_spec = { :location => new_resource.mount_point }
        else
            mount_spec = new_resource.mount_point
        end

        directory mount_spec[:location] do
            mode '0777'
            owner 'root'
            group 'root'
            recursive true
            not_if "mount | grep #{device_name}"
        end

        mount "mount_logical_volume_#{new_resource.group}_#{new_resource.name}" do
            mount_point mount_spec[:location]
            options     mount_spec[:options]
            dump        mount_spec[:dump]
            pass        mount_spec[:pass]
            device      device_name
            fstype      fs_type
            action      [:mount, :enable]
        end
    end
end