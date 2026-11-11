# ARTEX 部署手冊：GitHub → Harbor → Kubernetes

正式流程（GitLab CI/CD + ArgoCD，全自動）：

```
┌─ 開發機（外面）────┐  push   ┌─ 公司 GitLab ────────────────────────────┐
│ 改 code            │ ──────▶ │ CI pipeline（.gitlab-ci.yml 自動跑）：     │
└────────────────────┘         │  ① 測試                                   │
   │（可選）另外 push            │  ② docker build → push 到 Harbor          │
   ▼ GitHub 公開備份            │  ③ 新 image tag 寫回 k8s/artex.yaml       │
                               └───────────────────┬──────────────────────┘
                                                   │ ArgoCD 盯著 repo 的 k8s/
                               ┌───────────────────▼──────────────────────┐
                               │ k8s 叢集（ArgoCD 自動同步）                │
                               │   Pod: artex（Harbor image）              │
                               │   Pod: postgres（官方 image）             │
                               │   PVC: pgdata / artex-data / artex-keys  │
                               │        ↑ 資料活在這裡，與更新無關          │
                               └──────────────────────────────────────────┘
```

三個工具的分工：**GitLab CI** 是建造者（build + 推 Harbor + 改 tag）、**Harbor** 是倉庫（放 image）、**ArgoCD** 是部署者（讓叢集永遠等於 git 裡宣告的狀態）。你只負責 `git push`。

---

## Part 0：git remotes 配置（開發機，一次性）

目前配置：`origin` = 你的 GitHub（公開），`upstream` = 原專案 `BaaRai/ARTEX`。

到公司環境後，把**公司 GitLab**（部署來源，push 到它才會觸發 CI/CD）加進來，二選一：

```bash
# 方式一（推薦）：讓同一個 git push 同時送 GitHub 和 GitLab
git remote set-url --add --push origin git@github.com:<你的帳號>/xetra.git
git remote set-url --add --push origin git@gitlab.<你們的網域>:<group>/<repo>.git

# 方式二：GitLab 專案設定 pull mirroring（Settings → Repository → Mirroring），
# 讓 GitLab 自動從 GitHub 同步，你只 push GitHub（鏡像有幾分鐘延遲）
```

之後要同步上游更新時：`git fetch upstream && git merge upstream/main`（merge 前建議重跑一次稽核流程）。

## Part 1：一次性初始化

> **走 ArgoCD 正式流程的人注意**：1.3 和 1.4 的 `kubectl apply` 都會由 ArgoCD 代勞，
> 你實際要做的只有：1.2（secrets）→ Part 2 的 CI/ArgoCD 設定 → 回來做 1.5（初始化密碼）。
> 1.1、1.3、1.4 是給「沒有 CI/CD、純手動部署」的備用路徑用的。

### 1.1（備用路徑）拉程式碼、登入 Harbor

```bash
git clone <你的repo網址> artex && cd artex

# Harbor 上先建好一個 project（例如 library），並建一個 robot account 給部署用
docker login harbor.<你們的網域>
```

### 1.2 建 namespace 和 Secret（機密只用指令建，永遠不進 git）

```bash
kubectl create namespace artex

# 密碼請用「純英數」隨機字串（含 @ : / 等符號會弄壞 DSN）：
# 產生一組：LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; echo
kubectl -n artex create secret generic artex-secrets \
  --from-literal=POSTGRES_PASSWORD='<隨機英數密碼>' \
  --from-literal=ANTHROPIC_API_KEY='<你的key，沒有可先填空字串>'

# 讓叢集有權從 Harbor 拉 image（填 robot account 的帳密）
kubectl -n artex create secret docker-registry harbor-pull \
  --docker-server=harbor.<你們的網域> \
  --docker-username='robot$<名稱>' \
  --docker-password='<robot密碼>'
```

### 1.3（備用路徑）起資料庫

```bash
kubectl -n artex apply -f k8s/postgres.yaml
kubectl -n artex get pods -w        # 等 postgres-0 變成 1/1 Running 後 Ctrl-C
```

### 1.4（備用路徑）建第一版 image、改好 image 路徑、起 ARTEX

```bash
# 建置並推送第一版（之後都交給 update.sh，這裡手動跑一次一樣的事）
export HARBOR_IMAGE=harbor.<你們的網域>/library/artex   # 建議寫進 ~/.bashrc
docker build -t "$HARBOR_IMAGE:init" .
docker push "$HARBOR_IMAGE:init"

# 編輯 k8s/artex.yaml，把 image: 的 CHANGE_ME 整行改成：
#   image: harbor.<你們的網域>/library/artex:init
kubectl -n artex apply -f k8s/artex.yaml
kubectl -n artex get pods -w        # 等 artex-xxx 變成 1/1 Running
```

### 1.5 初始化管理密碼

ARTEX 第一次啟動需要 setup token（印在伺服器 log 裡）完成初始化：

```bash
kubectl -n artex logs deploy/artex | grep -i token   # 記下 setup token

# 先用 port-forward 連上 UI（在能開瀏覽器的機器上執行）：
kubectl -n artex port-forward svc/artex 8787:8787
# 瀏覽器開 http://localhost:8787 → 用 setup token 設定密碼
```

### 1.6（可選）對外入口與備份

團隊要透過網址使用的話，依你們叢集的 ingress 規範建一個指向 `svc/artex:8787` 的 Ingress，**務必上 TLS**，且不要暴露 8788。範例（nginx ingress，域名和 TLS 依環境調整）：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: artex
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"   # SSE 長連線
spec:
  ingressClassName: nginx
  tls:
    - hosts: [artex.internal.example.com]
      secretName: artex-tls
  rules:
    - host: artex.internal.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: artex
                port:
                  number: 8787
```

啟用每日自動備份（強烈建議）：

```bash
kubectl -n artex apply -f k8s/pg-backup-cronjob.yaml
```

## Part 2：正式流程 —— GitLab CI/CD + ArgoCD

### 2.1 一次性設定

**① GitLab CI 變數**（專案的 Settings → CI/CD → Variables，都勾 Masked）：

| 變數 | 內容 |
|---|---|
| `HARBOR_HOST` | `harbor.<你們的網域>` |
| `HARBOR_PROJECT` | Harbor 上的 project 名（例如 `library`） |
| `HARBOR_USER` / `HARBOR_PASSWORD` | Harbor robot account 帳密 |
| `PUSH_TOKEN` | 本專案的 Project Access Token（Settings → Access tokens，role **Developer**、scope **write_repository**）——讓 CI 能把新 image tag commit 回 repo |

**② 註冊 ArgoCD Application**：把 `argocd/application.yaml` 裡的 `repoURL` 改成你們 GitLab 上這個專案的網址，然後 `kubectl apply -f argocd/application.yaml -n argocd`（沒有 ArgoCD 權限就把這個檔交給平台組幫你註冊；私有 repo 還需要在 ArgoCD 加 repo 的讀取憑證，平台組通常有標準做法）。

**③ Secrets**：照 1.2 在 `artex` namespace 建好 `artex-secrets` 和 `harbor-pull`（ArgoCD 不管機密，這步永遠手動）。

**④ 第一次部署順序**：先 `git push` 讓 pipeline 跑完（image 進 Harbor、`k8s/artex.yaml` 的 tag 被 CI 改成真實版本）→ 再註冊 ArgoCD app → ArgoCD 自動把 postgres、artex、備份 CronJob 全部建起來 → 做 1.5 初始化密碼。

### 2.2 日常更新（每次改完 code）

```bash
git add -A && git commit -m "..." && git push
```

**就這一步。** 之後全自動：pipeline 跑測試 → build → 推 Harbor → 改 tag → ArgoCD 同步。進度看兩個地方：GitLab 的 Pipelines 頁面（build 有沒有過）、ArgoCD UI 的 artex app（同步了沒、Pod 健康嗎）。

### 2.3 回滾

GitOps 下回滾 = 把 git 退回去：

```bash
git revert <出問題的commit> && git push    # pipeline 會 build 回滾版並自動部署
# 或在 ArgoCD UI 的 History and Rollback 選一個舊版本（臨時手段，git 仍是真相來源）
```

### 2.4 重要觀念

ArgoCD 開著 `selfHeal`，叢集上任何手動改動（包括 `kubectl set image`）都會被自動改回 git 宣告的狀態——**所以一切變更都走 git commit**，這正是防止「有人偷偷改了正式環境」的機制，和你之前擔心的偷換 image 是同一類防護。

### 2.5 沒有 ArgoCD 權限？——按情境對號入座

多數公司的 ArgoCD 由平台組管理，你碰不到是正常的。先問平台組一句話：
「**我有一個 GitLab repo，k8s manifests 在 `k8s/` 目錄，要部署到叢集的 `artex` namespace，你們 ArgoCD 的接入方式是什麼？**」答案通常是以下其中一種：

**情境 A：平台組幫你註冊 Application（最常見）**
把三個資訊給他們：repo 網址、path `k8s/`、目標 namespace `artex`（或直接把 `argocd/application.yaml` 給他們參考）。若你連 kubectl 權限都沒有，把 1.2 建 secret 的指令一併貼給他們代跑。註冊完成後你的日常流程不變：`git push` 即部署。

**情境 B：公司規定 manifests 要放獨立的「部署 repo」（CD repo）**
平台組給你一個部署 repo，ArgoCD 盯的是它而不是你的程式 repo。做法：把 `k8s/` 整個目錄複製到那個 repo → 把 `.gitlab-ci.yml` 的 `bump-manifest` job 換成「clone 部署 repo、改 tag、push 回去」：

```yaml
bump-manifest:
  stage: deploy
  image: alpine:3.20
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  script:
    - apk add --no-cache git
    - git clone "https://oauth2:${CD_REPO_TOKEN}@gitlab.<你們的網域>/<group>/<部署repo>.git" cd-repo
    - 'sed -i "s|^\( *\)image: .*/artex:.*|\1image: ${IMAGE}:${CI_COMMIT_SHORT_SHA}|" cd-repo/k8s/artex.yaml'
    - cd cd-repo
    - git config user.name gitlab-ci && git config user.email gitlab-ci@invalid.local
    - git commit -am "deploy artex ${CI_COMMIT_SHORT_SHA}"
    - git push
```

（`CD_REPO_TOKEN` = 部署 repo 的 Access Token，加進 CI Variables；原本的 `PUSH_TOKEN` 就不需要了）

**情境 C：沒有 ArgoCD，但 GitLab Runner 連得到叢集**
刪掉 `bump-manifest`，換成 CI 直接下 kubectl（第一次要先照 Part 1 備用路徑手動 `kubectl apply -f k8s/` 把資源建起來）：

```yaml
deploy:
  stage: deploy
  image: bitnami/kubectl:1.31
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual        # 手動按一下才部署，比較安全
  script:
    - kubectl -n artex set image deployment/artex artex=$IMAGE:$CI_COMMIT_SHORT_SHA
    - kubectl -n artex rollout status deployment/artex --timeout=300s
```

（Runner 連叢集的方式問平台組：通常是 GitLab Agent for Kubernetes，或給你一份 KUBECONFIG 存成 CI 變數）

**情境 D：什麼自動化都接不上**
照 Part 2B 手動流程做，一樣能動。

不管哪個情境，不變的三件事：image 一律由 CI 建好推進 **Harbor**、tag 一律用 **commit SHA**（可追溯可回滾）、**secrets 一律手動建**（永不進 git）。

## Part 2B（備用）：沒有 CI/CD 時的手動更新

> 只適用於叢集**沒有**被 ArgoCD 管理時（否則 set image 會被 selfHeal 改回去）。

```bash
cd artex && git pull
./k8s/update.sh      # build → push Harbor → kubectl set image → 等滾動更新完成
kubectl -n artex rollout undo deployment/artex   # 手動流程的回滾
```

## Part 3：資料為什麼不會因為更新而消失

1. **資料不在容器裡，在 PVC 裡。** Pod 是用完即棄的；`pgdata`（資料庫）、`artex-data`（任務檔）、`artex-keys`（登入金鑰）三顆 PVC 的生命週期獨立於任何 Pod。更新 = 換掉 artex Pod 的 image，PVC 原封不動地掛回新 Pod。
2. **更新 artex 完全不碰 postgres。** `update.sh` 只動 `deployment/artex`，資料庫 Pod 連重啟都不會。
3. **schema 變更自動處理。** ARTEX 每次啟動會冪等地重跑 schema（`ADD COLUMN IF NOT EXISTS` 式），官方說法是「restart 即 migrate」，不需要手動遷移。

**會把資料弄丟的操作（不要做）：**

- `kubectl delete pvc ...`、`kubectl delete namespace artex`（刪 namespace 會連 PVC 一起刪）
- `kubectl delete statefulset postgres` 本身不會刪 PVC，但接著手滑刪 PVC 就沒了
- 改 `postgres.yaml` 的 volumeClaimTemplates 名稱（會指向一顆全新的空 PVC）

### 備份與還原

```bash
# 手動備份一份（隨時可做）
kubectl -n artex exec postgres-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump --clean --if-exists -U artex artex' | gzip > artex-$(date +%F).sql.gz

# 看自動備份的檔案
kubectl -n artex run -it --rm peek --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"peek","image":"busybox","command":["ls","-lh","/backup"],"volumeMounts":[{"name":"b","mountPath":"/backup"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"pg-backup"}}]}}'

# 還原（會覆蓋現有資料，先停 artex 避免寫入）
kubectl -n artex scale deployment/artex --replicas=0
gunzip -c artex-2026-11-12.sql.gz | kubectl -n artex exec -i postgres-0 -- sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U artex artex'
kubectl -n artex scale deployment/artex --replicas=1
```

## 常用檢查指令

```bash
kubectl -n artex get pods                      # 一切是否 Running
kubectl -n artex logs -f deploy/artex          # ARTEX log
kubectl -n artex logs postgres-0               # DB log
kubectl -n artex describe pod <pod名>          # Pod 起不來時看原因（拉不到 image、PVC 掛不上…）
kubectl -n artex get pvc                       # 三顆 PVC 是否 Bound
kubectl -n artex get cronjob,job               # 備份有沒有在跑
```

## 檔案對照表

| 檔案 | 誰用它 |
|---|---|
| `.gitlab-ci.yml` | GitLab CI 自動讀：測試、build 推 Harbor、把新 tag 寫回 manifest |
| `argocd/application.yaml` | 註冊給 ArgoCD：盯著本 repo 的 `k8s/` 自動同步叢集 |
| `k8s/*.yaml` | ArgoCD 同步的對象（= 叢集的期望狀態） |
| `k8s/update.sh` | 備用：沒有 CI/CD 時的手動部署 |
