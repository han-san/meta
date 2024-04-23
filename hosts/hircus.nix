{ config, pkgs, lib, options, modulesPath, ... }:
let
  domain = "dalo.se";
  hostName = "hircus";
  fqdn = "${hostName}.live.${domain}";

  secrets =
    builtins.mapAttrs (name: value: "/run/agenix/${name}") (import ./secrets);
in {
  # Agenix for secrets
  imports = [
    "${(import ./nix/sources.nix).agenix}/modules/age.nix"
    (modulesPath + "/profiles/qemu-guest.nix")
  ];
  services.qemuGuest.enable = true;
  environment.systemPackages = with pkgs; [ micro bat ];
  
  # Hardware
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = { device = "/dev/sda1"; fsType = "btrfs"; options = [ "compress-force=zstd" ]; };

  virtualisation.docker.enable = true;

  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "22.05"; # Did you read the comment?

  services.openssh.enable = true;
  services.openssh.passwordAuthentication = false;

  users.users.pazuzu = {
    description = "Administrator account";
    extraGroups = [ "wheel" "docker" ];
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
        "INSERT SSH KEYS HERE"
        ];
  };

  age.secrets = let
    noPublicKeys = builtins.mapAttrs
      (name: lib.filterAttrs (name: value: name != "publicKeys"));
    # (name: secret: builtins.removeAttrs secret [ "publicKeys"] )
    withFile = builtins.mapAttrs
      (name: value: value // { file = ./secrets + "/${name}.age"; });
  in withFile (noPublicKeys (import ./secrets));

  networking = {
    inherit domain hostName fqdn;
    nameservers = [ "1.1.1.1" "8.8.8.8" ];
    useNetworkd = true;
    firewall.allowedTCPPorts = [ 80 443 ];
    interfaces."ens18".useDHCP = true;
  };


  services.ddclient = {
    enable = true;
    # ddclient hasn't made a new release in 2y+ so we
    # use the latest commit before new build system
    package = pkgs.ddclient.overrideAttrs (old: {
      src = pkgs.fetchFromGitHub {
        owner = "ddclient";
        repo = "ddclient";
        rev = "18cc3a99e9e8bf8cb6b5b557becd5d0988f080b6";
        sha256 = "sha256-OajmhUdQy73I6HUMEi+kJb1Vu5C0GJb/h22H+Z/6m04=";
      };
    });
    protocol = "cloudflare";
    username = "token";
    passwordFile = "/run/agenix/cloudflare-dyndns";
    zone = "${domain}";
    domains = [ "${fqdn}" ];
    use = "if";
    extraConfig = "if=ens18";
  };

  # <3 Let's Encrypt
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "styr@dalo.se";

  # Basic services
  services.postgresql.enable = true;

  # Nginx
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
  };

  # S3 Block storage
  # Login to s3admin to create a new bucket
  services.minio = {
    enable = true;
    rootCredentialsFile = "/run/agenix/minio-root-cred";
  };
  services.nginx.virtualHosts."s3.${domain}" = {
    enableACME = true;
    addSSL = true;
    locations."/".proxyPass = "http://localhost:9000";
  };
  services.nginx.virtualHosts."s3admin.${domain}" = {
    enableACME = true;
    addSSL = true;
    locations."/".proxyPass = "http://localhost:9001";
  };

  # Vault Warden - FOSS Bitwarden server
  services.vaultwarden = {
    enable = true;
    environmentFile = "/run/agenix/vaultwarden-env-file"; # Sets ADMIN_TOKEN
  };
  services.nginx.virtualHosts."vault.${domain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/".proxyPass = "http://localhost:8000";
  };


  # NextCloud
  services.postgresql.ensureDatabases = [ "nextcloud" ];
  services.postgresql.ensureUsers = [{
    name = "nextcloud";
    ensurePermissions."DATABASE nextcloud" = "ALL PRIVILEGES";
  }];
  systemd.services."nextcloud-setup" = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
    postStart = "nextcloud-occ db:add-missing-indices";
  };
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud25;
    enableBrokenCiphersForSSE = false;

    hostName = "files.${domain}";
    https = true;
    config = {
      dbtype = "pgsql";
      dbhost = "/run/postgresql";

      adminuser = "root";
      adminpassFile = "/run/agenix/nextcloud-root-pass";

      defaultPhoneRegion = "SE";

      objectstore.s3 = {
        enable = true;
        hostname = "s3.${domain}";
        key = "nextcloud";
        secretFile = "/run/agenix/nextcloud-minio-secret";
        bucket = "nextcloud";
        region = "us-east-1";
        usePathStyle = true;
        autocreate = true;
      };
    };

    #poolSettings = options.services.nextcloud.poolSettings.default //
    #  { "access.log" = "/var/lib/nextcloud/access.log"; };
    phpOptions = options.services.nextcloud.phpOptions.default //
      { "opcache.interned_strings_buffer" = "10"; };
  };
  services.nginx.virtualHosts."files.${domain}" = {
    enableACME = true;
    addSSL = true;

    locations."~ ^\\/(?:store-apps|nix-apps)\\/richdocumentscode\\/proxy\\.php" = let
      nextcloud = config.services.nextcloud;
      fpm = config.services.phpfpm.pools.nextcloud;
    in {
      priority = 200;
      root = nextcloud.home;
      # https://github.com/NixOS/nixpkgs/blob/nixos-21.11/nixos/modules/services/web-apps/nextcloud.nix#L869
      extraConfig = ''
        include ${config.services.nginx.package}/conf/fastcgi.conf;
        fastcgi_split_path_info ^(.+?\.php)(\\/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS ${if nextcloud.https then "on" else "off"};
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:${fpm.socket};
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_read_timeout 120s;
      '';
    };
  };

   virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      dalo = {
        image = "ghcr.io/dalo-mdu/dalo.se:main";
        ports = [ "3000:3000" ];
        environment = {
          NODE_ENV = "production";
          PORT = "3000";
          CONTACT_WEBHOOK_URL= "";
        };
      };
    };
   };

  

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    addSSL = true;
    locations."/".proxyPass = "http://localhost:3000";
  };
  
  services.nginx.virtualHosts."www.${domain}" = {
    enableACME = true;
    addSSL = true;
    locations."/".return = "302 https://dalo.se";
  };
}
