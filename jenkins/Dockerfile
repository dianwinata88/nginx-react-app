FROM jenkins/jenkins:lts

USER root

# docker CLI + compose plugin (control the host daemon via mounted socket) + curl for health checks
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.3.1.tgz \
       | tar xz --strip-components=1 -C /usr/local/bin docker/docker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
       https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
    && rm -rf /var/lib/apt/lists/*

USER jenkins

# Plugins: pipeline, git-from-SCM, docker agents, ssh deploy, credentials, JCasC, Job DSL seed, github webhook
RUN jenkins-plugin-cli --plugins \
    workflow-aggregator \
    git \
    docker-workflow \
    ssh-agent \
    credentials-binding \
    configuration-as-code \
    job-dsl \
    github
