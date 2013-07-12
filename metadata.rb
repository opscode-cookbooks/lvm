name              "lvm"
maintainer        "Opscode, Inc."
maintainer_email  "cookbooks@opscode.com"
license           "Apache 2.0"
description       "Installs lvm2 package"
version           "0.8.11"

recipe "lvm", "Installs lvm2 package"

%w{ redhat centos debian ubuntu sles }.each do |os|
  supports os
end
