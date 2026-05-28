# Reproducible image for the synthetic RWE HPV vaccine-effectiveness pipeline.
#
# Base: rocker/r2u provides R on Ubuntu 22.04 with bspm, so install.packages()
# pulls precompiled apt binaries (incl. duckdb) — fast, deterministic builds,
# no source compilation.
FROM rocker/r2u:22.04

# System tooling: make for the pipeline, curl/gdebi to install Quarto.
RUN apt-get update && apt-get install -y --no-install-recommends \
        make git curl gdebi-core \
    && rm -rf /var/lib/apt/lists/*

# R package dependencies (binary installs via bspm).
RUN install2.r --error --skipinstalled \
        DBI duckdb survival ggplot2 testthat knitr rmarkdown

# Quarto for the dashboard (pinned).
ARG QUARTO_VERSION=1.5.57
RUN curl -fsSL -o /tmp/quarto.deb \
        "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
    && gdebi -n /tmp/quarto.deb \
    && rm /tmp/quarto.deb

WORKDIR /work
COPY . /work

# Default: run the whole pipeline end to end.
CMD ["make", "all"]
