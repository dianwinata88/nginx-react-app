// Active-active deploy pipeline: checkout -> test/build -> image -> rolling deploy A then B -> verify.
// Three deploy modes:
//   native-hosts  — simulate two VM hosts on this machine, reached over SSH exactly
//                   like production: stop the host's nginx, rsync the build, restart it.
//   compose-local — simulate on the Jenkins host's docker (docker compose up per node)
//   ssh           — production: SSH to each node host and run scripts/deploy-node.sh
pipeline {
    agent none

    parameters {
        choice(
            name: 'DEPLOY_MODE',
            choices: ['native-hosts', 'compose-local', 'ssh'],
            description: 'native-hosts simulates two VM hosts over SSH; compose-local simulates on docker; ssh deploys to production nodes'
        )
        booleanParam(
            name: 'PUSH_IMAGE',
            defaultValue: false,
            description: 'Push the built image to GHCR (needs ghcr-creds credential)'
        )
        string(name: 'IMAGE_TAG', defaultValue: 'latest', description: 'Tag for the app image')
        string(name: 'DEPLOY_USER', defaultValue: 'deploy', description: 'SSH user on node hosts (ssh mode)')
        string(name: 'NODE_A_HOST', defaultValue: '', description: 'Node A host (ssh mode)')
        string(name: 'NODE_B_HOST', defaultValue: '', description: 'Node B host (ssh mode)')
        string(name: 'LB_HOST', defaultValue: '', description: 'Load balancer host (ssh mode)')
    }

    environment {
        IMAGE    = 'ghcr.io/dianwinata88/nginx-react-app'
        // compose-local mode only: repo path that exists identically inside the
        // Jenkins container and on the docker host (bind-mounted there by
        // docker-compose.jenkins.yml) so relative compose volume mounts resolve.
        REPO_DIR = '/home/ubuntu/repos/nginx-react-app'
        // native-hosts mode: the two "VM hosts" live on the docker host itself,
        // reached over SSH (host.docker.internal -> host gateway in compose).
        SIM_USER  = 'ubuntu'
        SIM_HOST  = 'host.docker.internal'
        SIM_KEY   = '/keys/sim_deploy_key'
        SIM_DIR   = '/home/ubuntu/nodocker-sim'
        NGINX_BIN = '/home/ubuntu/nodocker-sim/nginx-1.31.6/usr/sbin/nginx'
    }

    stages {
        stage('Checkout') {
            agent any
            steps { checkout scm }
        }

        stage('Test & Build') {
            agent {
                docker {
                    image 'node:20-alpine'
                    args '-u root'
                }
            }
            steps {
                dir('app') {
                    sh 'npm ci'
                    sh 'npm test'
                    sh 'npm run build'
                }
            }
        }

        stage('Docker image') {
            agent any
            steps {
                sh "docker build -t ${IMAGE}:${params.IMAGE_TAG} -t nginx-react-app:local ."
            }
        }

        stage('Push image') {
            agent any
            when { expression { params.PUSH_IMAGE } }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'ghcr-creds',
                    usernameVariable: 'GHCR_USER',
                    passwordVariable: 'GHCR_TOKEN'
                )]) {
                    sh '''
                        echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
                        docker push $IMAGE:$IMAGE_TAG
                    '''
                }
            }
        }

        stage('Deploy node A') {
            agent any
            steps { script { deployNode('node-a') } }
        }

        stage('Deploy node B') {
            agent any
            steps { script { deployNode('node-b') } }
        }

        stage('Verify') {
            agent any
            steps {
                script {
                    if (params.DEPLOY_MODE == 'ssh') {
                        sh "for i in 1 2 3 4; do curl -fsS http://${params.LB_HOST}/healthz; sleep 1; done"
                    } else if (params.DEPLOY_MODE == 'native-hosts') {
                        sh 'for i in 1 2 3 4; do curl -fsS http://host.docker.internal:9090/healthz; sleep 1; done'
                        sh 'curl -fsS http://host.docker.internal:9090/version.txt'
                    } else {
                        // Jenkins container shares the app compose network.
                        sh 'for i in 1 2 3 4; do curl -fsS http://lb/healthz; sleep 1; done'
                    }
                }
            }
        }
    }
}

// Rolling deploy of one node; the peer absorbs traffic meanwhile.
def deployNode(String node) {
    if (params.DEPLOY_MODE == 'ssh') {
        def host = (node == 'node-a') ? params.NODE_A_HOST : params.NODE_B_HOST
        sshagent(credentials: ['deploy-ssh-key']) {
            sh """
                ssh -o StrictHostKeyChecking=accept-new ${params.DEPLOY_USER}@${host} \\
                    'NODE_ID=${node} IMAGE_TAG=${params.IMAGE_TAG} GHCR_TOKEN=\$GHCR_TOKEN bash -s' \\
                    < ${WORKSPACE}/scripts/deploy-node.sh
            """
        }
        sh "for i in \$(seq 30); do curl -fs http://${host}/healthz && exit 0; sleep 2; done; exit 1"
    } else if (params.DEPLOY_MODE == 'native-hosts') {
        def dir     = "${SIM_DIR}/${node}"
        def port    = (node == 'node-a') ? '9091' : '9092'
        def sshOpts = "-i ${SIM_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        def sshCmd  = "ssh ${sshOpts} ${SIM_USER}@${SIM_HOST}"
        sh """
            ${sshCmd} 'readlink /proc/\$(cat ${dir}/nginx.pid)/exe 2>/dev/null || echo "no running nginx"'
            ${sshCmd} 'test -f ${dir}/nginx.pid && kill -QUIT \$(cat ${dir}/nginx.pid); for i in \$(seq 20); do test -f ${dir}/nginx.pid || break; sleep 1; done; if test -f ${dir}/nginx.pid; then echo "drain timeout"; exit 1; fi'
            rsync -az --delete -e 'ssh ${sshOpts}' ${WORKSPACE}/app/dist/ ${SIM_USER}@${SIM_HOST}:${dir}/html/
            ${sshCmd} 'printf "window.__NODE_ID__=\\"${node}\\";" > ${dir}/html/config.js'
            ${sshCmd} 'echo "v2 react-19 nginx-1.31.6" > ${dir}/html/version.txt'
            ${sshCmd} '${NGINX_BIN} -v 2>&1 && ${NGINX_BIN} -p ${dir} -c conf/nginx.conf'
            ${sshCmd} 'readlink /proc/\$(cat ${dir}/nginx.pid)/exe'
        """
        sh "for i in \$(seq 30); do curl -fs http://${SIM_HOST}:${port}/healthz && exit 0; sleep 2; done; exit 1"
    } else {
        sh "cd ${REPO_DIR} && docker compose up -d --no-deps --force-recreate ${node}"
        sh "for i in \$(seq 30); do curl -fs http://${node}/healthz && exit 0; sleep 2; done; exit 1"
    }
}
