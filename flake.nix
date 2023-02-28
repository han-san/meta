{
	inputs = {
    nixpkgs.url = "github:NixOs/nixpkgs";
  };
  outputs = {nixpkgs, ...}: {
    nixosConfigurations."hircus" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        (import ./hosts/hircus.nix)
      ];
    };
  };
}
