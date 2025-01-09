{ pkgs ? import <nixpkgs> {} }:
let
    talhelper =  pkgs.callPackage (builtins.fetchGit {
        url = "https://github.com/budimanjojo/talhelper";
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
        k9s
        fluxcd
    ];
}
