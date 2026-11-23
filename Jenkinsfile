// v1.2.3 形式のタグでは、署名・GitHub Release・Homebrew tap 更新まで進む。
// Jenkins 全体の MORN_RELEASE_DRY_RUN が false になるまでは、外に出る処理をせずやることを表示するだけ
@Library('MornJenkins') _
pipeline {
  agent { label 'built-in' }
  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '3'))
  }
  environment {
    DRY_RUN = "${env.MORN_RELEASE_DRY_RUN == 'false' ? 'false' : 'true'}"
  }
  stages {
    stage('Tools') {
      steps { mornToolVersions() }
    }
    stage('Lint') {
      steps {
        sh 'zsh -n build.sh'
        sh 'ruby -c Support/mornrunner.rb.in'
      }
    }
    stage('Test') {
      steps { sh 'swift test' }
    }
    stage('Build') {
      steps {
        sh '''
          if [ -n "${TAG_NAME:-}" ]; then export VERSION="${TAG_NAME#v}"; fi
          UNIVERSAL=1 zsh build.sh
        '''
      }
    }
    stage('Verify') {
      steps {
        sh '''
          app=dist/MornRunner.app
          test "$(lipo -archs "$app/Contents/MacOS/MornRunner" | tr ' ' '\\n' | sort | xargs)" = "arm64 x86_64"
          codesign --verify --strict -vv "$app"
          test -s "$app/Contents/Resources/AppIcon.icns"
          test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = studio.tsukumi.MornRunner
          if [ -n "${TAG_NAME:-}" ]; then
            test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "${TAG_NAME#v}"
          fi
        '''
        archiveArtifacts artifacts: 'dist/MornRunner.app.zip', fingerprint: true
      }
    }
    stage('Release') {
      when { tag pattern: 'v\\d+\\.\\d+\\.\\d+', comparator: 'REGEXP' }
      environment {
        VERSION = "${env.TAG_NAME.substring(1)}"
      }
      stages {
        // MornNotary の sign.sh が段階呼び出し (request/wait/fetch) に対応していなければ、Request で一括して行う
        stage('Sign: Request') {
          steps {
            script {
              if (env.DRY_RUN == 'true') {
                echo 'DRY RUN: matsufriends/MornNotary に dist/MornRunner.app の署名・公証を依頼する'
                return
              }
              withCredentials([string(credentialsId: 'morn-notary-token', variable: 'GH_TOKEN')]) {
                sh '''
                  rm -rf notary
                  mkdir -p notary/state
                  gh repo clone matsufriends/MornNotary notary/MornNotary -- --depth 1
                  if grep -q '^  request)' notary/MornNotary/sign.sh; then
                    bash notary/MornNotary/sign.sh request dist/MornRunner.app notary/state
                  else
                    bash notary/MornNotary/sign.sh dist/MornRunner.app
                  fi
                '''
              }
            }
          }
        }
        stage('Sign: Wait') {
          steps {
            script {
              if (env.DRY_RUN == 'true') {
                echo 'DRY RUN: MornNotary の署名 run が署名済みの Artifact を上げるまで待つ'
                return
              }
              withCredentials([string(credentialsId: 'morn-notary-token', variable: 'GH_TOKEN')]) {
                sh 'if [ -f notary/state/request.env ]; then bash notary/MornNotary/sign.sh wait notary/state; fi'
              }
            }
          }
        }
        stage('Sign: Fetch') {
          steps {
            script {
              if (env.DRY_RUN == 'true') {
                echo 'DRY RUN: 署名済みの ZIP を取り出し、MornNotary の依頼ブランチと Artifact を消す'
                return
              }
              withCredentials([string(credentialsId: 'morn-notary-token', variable: 'GH_TOKEN')]) {
                sh '''
                  if [ -f notary/state/request.env ]; then bash notary/MornNotary/sign.sh fetch notary/state; fi
                  mv dist/MornRunner-signed.zip dist/MornRunner.app.zip
                  rm -rf notary
                '''
              }
            }
          }
        }
        stage('Verify signed') {
          when { environment name: 'DRY_RUN', value: 'false' }
          steps {
            sh '''
              out=$(mktemp -d)
              trap 'rm -rf "$out"' EXIT
              ditto -x -k dist/MornRunner.app.zip "$out"
              app="$out/MornRunner.app"
              codesign --verify --strict --deep -vv "$app"
              assessed=$(spctl --assess --type execute -vv "$app" 2>&1) || true
              echo "$assessed"
              grep -q 'Notarized Developer ID' <<<"$assessed"
              xcrun stapler validate "$app"
            '''
            archiveArtifacts artifacts: 'dist/MornRunner.app.zip', fingerprint: true
          }
        }
        stage('Publish: GitHub Release') {
          steps {
            script {
              if (env.DRY_RUN == 'true') {
                echo "DRY RUN: TsukumiStudio/MornRunner に ${env.TAG_NAME} の Release を作り、MornRunner.app.zip を載せる"
                return
              }
              withCredentials([usernamePassword(credentialsId: 'github-app-tsukumistudio', usernameVariable: 'GH_APP', passwordVariable: 'GH_TOKEN')]) {
                sh '''
                  if gh release view "$TAG_NAME" -R TsukumiStudio/MornRunner >/dev/null 2>&1; then
                    gh release upload "$TAG_NAME" dist/MornRunner.app.zip --clobber -R TsukumiStudio/MornRunner
                  else
                    gh release create "$TAG_NAME" dist/MornRunner.app.zip --generate-notes --verify-tag -R TsukumiStudio/MornRunner
                  fi
                '''
              }
            }
          }
        }
        stage('Publish: Homebrew') {
          steps {
            withCredentials([usernamePassword(credentialsId: 'github-app-tsukumistudio', usernameVariable: 'GH_APP', passwordVariable: 'GH_TOKEN')]) {
              sh '''
                rm -rf tap
                gh repo clone TsukumiStudio/homebrew-tap tap -- --depth 1
                sha=$(shasum -a 256 dist/MornRunner.app.zip | awk '{print $1}')
                mkdir -p tap/Casks
                sed -e "s/@VERSION@/${VERSION}/g" -e "s/@SHA256@/${sha}/g" Support/mornrunner.rb.in > tap/Casks/mornrunner.rb
                ruby -c tap/Casks/mornrunner.rb
                git -C tap diff
                if [ "$DRY_RUN" = true ]; then
                  echo 'DRY RUN: 上の差分を TsukumiStudio/homebrew-tap の main に push する'
                  exit 0
                fi
                cd tap
                git config user.name 'mornjenkins[bot]'
                git config user.email '360150882+mornjenkins[bot]@users.noreply.github.com'
                git add Casks/mornrunner.rb
                if ! git diff --cached --quiet; then
                  git commit -m "mornrunner ${VERSION}"
                  git pull --rebase origin main
                  git push origin HEAD:main
                fi
              '''
            }
          }
        }
      }
    }
  }
}
