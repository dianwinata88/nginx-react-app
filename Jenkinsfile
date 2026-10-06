// Active-active deploy pipeline: checkout -> test/build -> image -> rolling deploy A then B -> verify.
// Two deploy modes:
//   compose-local — simulate on the Jenkins host's docker (docker compose up per node)
//   ssh           — production: SSH to each node host and run scripts/deploy-node.sh
pipeline {
    agent none

    parameters {
        choice(
            name: 'DEPLOY_MODE',
            choices: ['compose-local', 'ssh'],
            description: 'compose-local simulates on this docker host; ssh deploys to production nodes'
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
    } else {
        sh "cd ${REPO_DIR} && docker compose up -d --no-deps --force-recreate ${node}"
        sh "for i in \$(seq 30); do curl -fs http://${node}/healthz && exit 0; sleep 2; done; exit 1"
    }
}
