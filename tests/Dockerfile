# tests/Dockerfile: ubuntu:26.04 smoke test. Build from the repo root:
#   docker build -f tests/Dockerfile -t ostrich-os-test . && docker run --rm ostrich-os-test
FROM ubuntu:26.04

RUN apt-get update \
	&& apt-get install -y --no-install-recommends bats gjs python3 unzip dconf-cli dconf-service dbus-daemon dbus-bin \
	&& rm -rf /var/lib/apt/lists/*

# The installer refuses to run as root, so test as a normal user.
RUN useradd --create-home tester
COPY --chown=tester:tester . /home/tester/repo
USER tester
WORKDIR /home/tester/repo

CMD ["bash", "-c", "./install.sh --dry-run && bats tests/ && tests/js-test.sh"]
