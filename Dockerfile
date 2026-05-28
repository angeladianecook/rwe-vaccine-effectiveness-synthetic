# Pinned R base image for deterministic builds.
FROM rocker/r-ver:4.4.1

# System libraries commonly needed by the analysis/dashboard stack.
RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        git \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libfontconfig1-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libfreetype6-dev \
        libpng-dev \
        libtiff5-dev \
        libjpeg-dev \
    && rm -rf /var/lib/apt/lists/*

# Quarto for the dashboard (version pinned).
ARG QUARTO_VERSION=1.5.57
RUN curl -fsSL -o /tmp/quarto.deb \
        "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
    && dpkg -i /tmp/quarto.deb \
    && rm /tmp/quarto.deb

WORKDIR /work

# Dependency restore happens via renv once the lockfile exists.
# COPY renv.lock renv.lock
# RUN R -e "install.packages('renv'); renv::restore()"

COPY . /work

# Default: run the full pipeline.
CMD ["make", "all"]
