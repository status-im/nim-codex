#!/usr/bin/env groovy
library 'status-jenkins-lib@v1.9.13'

pipeline {
  agent { label 'linux' }

  options {
    disableConcurrentBuilds()
    /* manage how many builds we keep */
    buildDiscarder(logRotator(
      numToKeepStr: '20',
      daysToKeepStr: '30',
    ))
  }

  parameters {
    choice(
      name: 'VERBOSE',
      description: 'Level of verbosity based on nimbus-build-system setup.',
      choices: ['0', '1', '2']
    )
    choice(
      name: 'USE_SYSTEM_NIM',
      description: 'Decides whether to use system Nim compiler provided with Nix or not.',
      choices: ['0', '1']
    )
  }

  environment {
    /* Improve make performance */
    NUMPROC = "${sh(script: 'nproc', returnStdout: true).trim()}"
    MAKEFLAGS = "-j${env.NUMPROC} V=${params.VERBOSE}"
    /* Use system Nim compiler */
    USE_SYSTEM_NIM = "${params.USE_SYSTEM_NIM}"
  }

  stages {
    stage('Build') {
      steps {
        script {
          nix.flake(opts: [ submodules: true, rebuild: true, debug: true ])
        }
      }
    }
  }

  post {
    cleanup { cleanWs() }
  }
}
