{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
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
        prometheus.cli
        apko
        grafana-loki.logcli
    ];
}
