{ pkgs ? import <nixpkgs> {} }:
let
    talhelper =  pkgs.callPackage (pkgs.fetchgit {
        url = "https://github.com/budimanjojo/talhelper";
        hash = "sha256-VEKl7ftH3GrhmRyIRCK2hkTb59vzmaHrlHIH21U2nOM=";
    }) {};
in pkgs.mkShell {
    packages = with pkgs; [
        talosctl
        argocd
        age
        sops
        kubectl
        kubernetes-helm
        talhelper
    ];
}
