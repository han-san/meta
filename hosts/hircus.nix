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


  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "22.05"; # Did you read the comment?

  services.openssh.enable = true;
  services.openssh.passwordAuthentication = false;

  users.users.pazuzu = {
    description = "The symbol of balance.";
    extraGroups = [ "wheel" "docker" ];
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDARnGYbUJkeo5NRINEpkgGT/LpeWGiKlL2oZeu21Or1EpC392cKz5jquz2PM7AkSVJqubMB0f6ZRVTVVDjyVgO7aHcCM4OomF031ORJq7uAHWOgUdkFtcs8Irb71xUnbU3u0L3KhlUTHTMaCULUccQmHX442Ao1spUjL0dOK5m2Eia5OTxkaWulilkYRWcGHPmTjumsyXhg5btgGnwVhAjRKS5sKei5cBgQwx6dCveYc06G0aDuS7PBpIFkT48lEh0sGPS8ijHU9E8urvFpHFPj/hFF9lsKKSwE8L8ASwuziN82TSIw/1xyEVe4IDXVBqfCMHCvZM3qFRJFy7VAnyX kng@hyperdrive"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIROYqN9O7ewlAYRMt1ROxxgKKfHOW31NJ06zCNaxwtn e@ukl_2021-11-04"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBoXPFt/ddFzJgHj2bAYRVfJ/FseIdASW2C26deW4ND2 e@arafel-2019-11-15"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDauQtPmqWaGQ4wB1kRa6tmPbTvfgfLWjP6rbsFjEij3 elit@1337book"
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
  security.acme.defaults.email = "kngrektor@gmail.com";

  # Basic services
  services.postgresql.enable = true;

  # Nginx
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
    # When Nginx can't find any virtual host matching
    # the host header it falls back to the "first" virtual host
    virtualHosts."a".locations."/".extraConfig = ''
      add_header Content-Type 'text/plain';
      return 200 'Host doesnt match any virtual host';
    '';
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

  # N8N
  #services.n8n.enable = true;
  #services.nginx.virtualHosts."n8n.${domain}" = {
  #  enableACME = true;
  #  forceSSL = true; 
  #  locations."/".proxyPass = "http://localhost:5678";  
  #};


  services.nginx.virtualHosts."${domain}" = let
    site = pkgs.stdenv.mkDerivation {
      name = "jekyll-dalo.se";
      nativeBuildInputs = with pkgs; [ jekyll ];
      src = pkgs.fetchFromGitHub {
        owner = "dalo-mdu";
        repo = "site";
        #rev = "f2e003d96b29375915dbc280c19840c7ee55c66c";
        #hash = "sha256-aUdsdS4ImlYeah0oZ9nr3heR/ZwWZm2A3VZrYXHkgTs=";
        #rev = "69f1eeb2713bbdee603b7cfbc3d4ed7da96b929e";
        #hash = "sha256-RAlvYwxvh9RXFRp+BfWeq+nGKp7yZzpVuIKl56La8pM=";
        #rev = "3cac2b763e153ef5f3abf4e41465562874c9e00b";
        #hash = "sha256-ZGQIZKf+9aL/7OyD0pO/zTJe/mFv5k9j39uhP8EqMXk=";
        #rev = "4bb8e8559a6a2dd39d494a0e604f10284290f297";
        #hash = "sha256-GeQ7w2ub5zXJ3j3J7V5fhB5LAkTdpYGQSr7RAvvxV3A=";
        rev = "31d4b7e280827e6231971df0cedcee16041c76c9";
        hash = "sha256-HnNWrma2+OzRnw2heS0QylHmOlirhVjzPZhBy6c7zBs=";
      };
      installPhase = ''
        mkdir "$out"
        jekyll build -d "$out"
      '';
    };
  in {
    enableACME = true;
    addSSL = true;
    locations."/".root = "${site}";
  };
  services.nginx.virtualHosts."old.${domain}" = {
    enableACME = true;
    addSSL = true;
    locations."/".return = "302 https://sites.google.com/site/daloget";
  };
  services.nginx.virtualHosts."www.${domain}" = {
    enableACME = true;
    addSSL = true;
    locations."/".return = "302 https://dalo.se";
  };

}
