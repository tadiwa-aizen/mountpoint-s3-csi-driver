# V2 → V3 Parity — decisions & customer experience ([S3-HPCC-545](https://taskei.amazon.dev/tasks/S3-HPCC-545))

This doc is where we agree the parity decisions between v2 and v3 — with the **customer experience** front and centre for each item (what an operator can configure, and what stays simple/safe for them).  

## Context

- **v2:** a per-node **CSI node DaemonSet** (`node.yaml`) **plus a Mountpoint pod per workload** (the "mount-runner" that runs `mount-s3`).
- **v3:** the same per-node **CSI node DaemonSet**, **plus one shared mounter DaemonSet** (`mounter-daemonset.yaml`) that runs all the `mount-s3` processes on a node.

The node pod does the FUSE mount and hands it to the mounter **on the same node**, so the two must land on the same nodes.

## Heterogeneous config (keep the door open)

"Heterogeneous config" = letting **different node types run different mounter settings** (memory, cache, `maxVolumesPerNode`), each targeting its own node pool. We are **not** building it now, but every decision below must **not be a one-way door** that blocks it later. In practice that means: keep `daemonsetMounters` a **list**, and don't delete the per-mounter knobs — so a future release can add per-node-type profiles without a breaking change.

---



- [ ] **1. Placement — `nodeSelector` & `affinity`**
  - Both are ways to tell Kubernetes **which nodes a pod is allowed to run on**. `nodeSelector` is the simple form ("only nodes with these labels"); `affinity` is a more flexible form of the same idea.
  - **Customer experience:** an operator should be able to choose **which nodes the driver runs on** in one place, and never worry about the node pod and the mounter ending up on different nodes. Later, they should be able to give different kinds of nodes different mounter settings — and adding that must not break anyone.
  - **The choice:** which pod owns the node-choice setting, and what does the other one do with it?
    - **Option A (Rajdeepa's suggestion) — mounters own placement; the node pod is derived from them.** Each mounter keeps its own `nodeSelector`. The chart then auto-generates the **node pod's `nodeAffinity` as the OR of every mounter's selector**. Kubernetes evaluates a pod's `nodeSelector` **AND** its `nodeAffinity` together, and the terms inside `nodeAffinity` are **OR'd** — so the node pod runs where `node.nodeSelector AND (mounterA OR mounterB OR …)`. Its own `node.nodeSelector` is untouched.

      ```yaml
      # node.yaml — chart-generated: node pod runs where ANY mounter runs (terms are OR'd)
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:              # one term per mounter, OR'd
              - matchExpressions: [{key: disktype, operator: In, values: [ssd]}]
              - matchExpressions: [{key: disktype, operator: In, values: [nvme]}]
      ```
      - *The win:* the node pod only lands on node types that actually have a mounter, so the **"gap" below is impossible by construction** — you can never have a node pod with no mounter. Prototyped and verified on a real 2-node cluster (**[Appendix D](#appendix-d-option-a-placement-test-rajdeepas-suggestion--real-eks-mp-dev-cluster-2-nodes-v3-daemonset-mode)**): with two mounters, a node matching no mounter got no node pod.
      - *The cost:* the chart must generate and re-render this OR block whenever the mounter list changes, and it **uses the node pod's `affinity` slot** — an operator who wants their own node affinity now has to have it merged with the generated OR. For one mounter (today) it's pure overhead.
    - **Option B — the node pod owns the base; the mounter only *adds* to it (never replaces it).** The node's `nodeSelector`/`affinity`/`tolerations` are the global "where can the driver run at all" boundary. Each mounter entry may add its own constraints on top; the chart ANDs them, so a mounter can only run on a **subset** of the node pod's nodes — never somewhere the node pod can't. With nothing extra (the default), it runs on exactly the node pod's nodes.

      - *How the AND works (no special logic):* a `nodeSelector` is already "match **all** these labels", so the chart just writes the node's labels and the mounter's labels into **one** block. The template in `mounter-daemonset.yaml`:
        ```yaml
        nodeSelector:
          kubernetes.io/os: linux
          {{- with .Values.node.nodeSelector }}   # node's labels (base)
          {{- toYaml . | nindent 8 }}
          {{- end }}
          {{- with $mounter.nodeSelector }}        # mounter's extra labels (narrows)
          {{- toYaml . | nindent 8 }}
          {{- end }}
        ```
        renders (verified with `helm template`, and live on a real 2-node cluster — **[Appendix C](#appendix-c-option-b-placement-test-real-eks-mp-dev-cluster-2-nodes-v3-daemonset-mode)**) to a single map — the node must match every key, so the mounter is a strict subset:
        ```yaml
        nodeSelector:
          kubernetes.io/os: linux
          disktype: ssd                           # from node
          s3.csi.aws.com/mounter-profile: large   # from mounter
        ```
      - *Heterogeneous only (not an Option B bug):* the "gap" — a node the node pod runs on but no mounter does — only exists if you run several mounters and give one a narrowing label that doesn't cover every node. It is **not introduced by Option B**: today's code already lets the mounter have its own selector, so the same mismatch is already possible (in fact worse, since today the two selectors are fully independent). In Option B's default (mounter inherits the node, no extra label) there is no gap. If/when heterogeneous is built, the intended guard is one `mounter-profile` label per node group + one mounter per value, with a chart `fail` on duplicates — **not built yet**, and a chart can't see node labels at render time so it also needs a runtime check. Standard pattern: NVIDIA's device plugin picks per-node config by a single label, and AWS EBS CSI's [`additionalDaemonSets`](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/charts/aws-ebs-csi-driver/values.yaml) does per-node settings the same way.
  - **A vs B — the real trade-off** (they're mirror images; pick which risk you'd rather own):

    | | **A (mounters own; node = OR of them)** | **B (node owns; mounter narrows)** |
    |---|---|---|
    | Simple/default case (one mounter) | generates node affinity even for one mounter — overhead | dead simple, one node knob |
    | The "gap" (only with several mounters: a node with a node pod but no mounter) | **impossible by construction** | possible if a mounter is narrowed off a node → wants a guard when heterogeneous is built |
    | Chart complexity | higher (generate + re-render node's OR affinity) | low |
    | Operator's own `node.affinity` | collides — must be merged with the generated OR | free to use |

    Net: **A trades chart-simplicity for gap-safety; B trades gap-safety for chart-simplicity.** For the ship-now single-mounter case B is simpler; for many mounters A removes a whole class of misconfiguration. Decision for Thursday.
  - **What we suggest — Option B.** The node pod owns "which nodes the driver runs on"; the mounter follows it and can only narrow to a subset, never point elsewhere. It's the simplest choice that stays safe: placement is set in one place, the two pods can't drift onto different nodes, and the door to per-node-type configs stays open (a mounter can add its own label later to target a node group). Option A is the fallback if we later want the gap ruled out entirely across many mounters.
- [ ] **2. Tolerations**
  - A **taint** is a "keep off" mark on a node; a **toleration** lets a pod stay anyway. For a `NoExecute` taint, a toleration also stops an **already-running** pod from being kicked off.
  - **Customer experience:** the mounter must run wherever the workloads do, and must never be kicked off a node before the workloads it serves.
  - **Our decision — the mounter uses the same tolerations as the node pod (it inherits them).** By default it just follows the node, so it tolerates at least everything the node pod does. We keep a per-mounter option to tolerate *extra* taints for the future heterogeneous case — a profile can only add, never remove.
    - *Why:* it guarantees the mounter tolerates at least everything the node pod does, so it can never be kicked off a node before the node pod — and therefore never before the workloads.
    - *Effect on eviction:* at the default (`tolerateAllTaints: true`) the mounter tolerates every taint, so a taint can't evict it at all (the full "why" is in item **3**). Inheriting the node pod's tolerations also means it's never *more* evictable than the node pod, in any config.
    - *One symmetry rule for later (heterogeneous):* a taint on a special node pool needs a toleration on **both** halves. So a profile's extra toleration must also be added to the node pod — otherwise the mounter could run where the node pod can't. (Not needed today with one mounter; called out so we don't forget when profiles land.) 

- [ ] **3. Eviction / shutdown order** — tested on real EKS.
  - The mounter serves the live I/O for every mount on the node, so it must never be torn down **before** the workloads using it.
  - **Customer experience:** a workload must never lose its mount ("transport endpoint not connected") because the mounter went away first — and the operator shouldn't have to configure anything to get that.
  - **What we tested (real EKS, v3 daemonset mode):**

    | # | What we did | What happened | As expected? |
    |---|---|---|---|
    | 1 | applied a `NoExecute` taint to the node (default config) | workload evicted; mounter never evicted | Yes |
    | 2 | ran `kubectl drain` on the node (default) | workload evicted; mounter stayed | Yes |
    | 3 | drained the node, with a 2nd node available (default) | workload moved to the other node and remounted (data intact) | Yes |
    | 4 | powered the node off cleanly — graceful shutdown (default) | workload terminated first; mounter terminated last | Yes |
    | 5 | applied a `NoExecute` taint with `tolerateAllTaints: false` | mounter evicted after ~300s | Yes — risky config |

  - **Why it behaves this way (in the code):**
    - *Taint:* the mounter tolerates all taints (`operator: Exists`, no timeout), so a `NoExecute` taint never evicts it.
    - *Drain:* `kubectl drain` skips DaemonSet pods, and the mounter is a DaemonSet.
    - *Shutdown:* the mounter is `system-node-critical`, and the kubelet stops critical pods **last** → after the workloads.
    - *Node pod vs mounter:* there's no strict order *between* the two — both are DaemonSets and both `system-node-critical`, so they behave the same. What matters is that both outlive the **workloads**, which they do.
  - **Conclusion:** at the shipped default the mounter is never removed before its workloads, and mounts recover if the workload moves — so it does **not** need the trick v2 used (v2's mountpoint pod ignored the shutdown signal and waited up to 10 minutes to outlive its workloads). The only way the mounter is evicted early is `tolerateAllTaints: false`, and in that config the node pod is evicted the same way → a deliberate operator choice, not a mounter bug. **Full writeup → [Appendix B](#appendix-b-eviction--shutdown-order-test).**

- [x] **4. Pod labels (`podLabels`)**
  - Extra labels an operator can stamp on the pod via a Helm value.
  - **Customer experience:** operators can tag the mounter pod with their own labels (for dashboards / policies / selectors), the same way they can the node pod.
  - **Our decision:** the mounter exposes the same option — `daemonsetMounters[0].podLabels` ([`mounter-daemonset.yaml#L27`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/feature/daemonset-architecture/charts/aws-mountpoint-s3-csi-driver/templates/mounter-daemonset.yaml#L27)) — mirroring the node pod's `node.podLabels` ([`node.yaml#L31-L32`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/charts/aws-mountpoint-s3-csi-driver/templates/node.yaml#L31-L32)). Done.

- [x] **5. kubeletPath**
  - Points the driver at a non-default kubelet directory (instead of `/var/lib/kubelet`) — e.g. microk8s (`/var/snap/microk8s/common/var/lib/kubelet`) or k0s.
  - **Customer experience:** operators on non-standard kubelet dirs set `node.kubeletPath` **once** and everything works — there's nothing mounter-specific to configure.
  - **Our decision:** the mounter needs no separate knob (it only has a small scratch volume, `/comm`); the node pod builds all mount/socket paths from `node.kubeletPath` (v2: [`node.yaml#L107-L108`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/charts/aws-mountpoint-s3-csi-driver/templates/node.yaml#L107-L108) env + [volumes `L209-L220`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/charts/aws-mountpoint-s3-csi-driver/templates/node.yaml#L209-L220)). Confirmed — tested end-to-end on a custom kubelet root (kind), plus unit tests (custom root) and every EKS e2e (default root). **Full test writeup → [Appendix A](#appendix-a-kubeletpath-test).**

- [x] **6. Priority class (`system-node-critical`)**
  - The pod's scheduling priority. `system-node-critical` is the highest built-in level, so the pod is scheduled ahead of others and is the last to be removed when a node is under pressure.
  - **Customer experience:** not an operator setting — **both pods are hardcoded to this class** (there's no knob and nothing to copy). The mounter is treated as critical node infrastructure, so it starts quickly and isn't pushed out before application pods.
  - **Our decision:** the mounter hardcodes the **same** class as the node pod ([`mounter-daemonset.yaml#L36`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/feature/daemonset-architecture/charts/aws-mountpoint-s3-csi-driver/templates/mounter-daemonset.yaml#L36) / [`node.yaml#L41`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/charts/aws-mountpoint-s3-csi-driver/templates/node.yaml#L41)) — which, as item **3** shows, is what makes it shut down *after* the workloads. Done.

- [x] **7. SELinux (`seLinuxOptions`)** — **paused.**
  - Sets the pod's SELinux label so mounts aren't blocked on SELinux-enforcing clusters.
  - **Customer experience:** on enforcing clusters, mounts should just work without the operator doing anything special.
  - **Status:** paused — pending Renan's process-isolation design (which may decide whether the mounter needs SELinux handling). Today the mounter has **no** `seLinuxOptions`, matching v2's mount-runner ([`creator.go#L145-L156`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/pkg/podmounter/mppod/creator.go#L145-L156)) — and mounts work; v2 puts the label only on the node pod ([`node.yaml#L86`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/charts/aws-mountpoint-s3-csi-driver/templates/node.yaml#L86)). Earlier SELinux PR [#940](https://github.com/awslabs/mountpoint-s3-csi-driver/pull/940) is closed.

- [x] **8. `hostPID`**
  - `hostPID: true` lets a pod see **all the processes running on the node**, not just its own.
  - **Customer experience:** internal detail — nothing for operators to set; behaviour matches v2.
  - **Our decision:** keep `hostPID: true` on the node pod ([`node.yaml#L68-L72`](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/charts/aws-mountpoint-s3-csi-driver/templates/node.yaml#L68-L72); `false` on OpenShift) — it needs this so Mountpoint can finish in-flight uploads cleanly on shutdown — and omit it on the mounter, same as the v2 mountpoint pod, which never set it. Done.

- [x] **9. HTTP proxy (`HTTPS_PROXY` / `NO_PROXY`)**
  - Routes Mountpoint's S3 traffic through an HTTP proxy, set per-volume via `mountpointEnv.*` volume attributes.
  - **Customer experience:** operators behind an egress proxy set `HTTPS_PROXY`/`NO_PROXY` on the volume and it just works — exactly as in v2.
  - **Our decision:** works the same in v3 — the driver reads `mountpointEnv.*` and passes them to the `mount-s3` process; no driver change needed. The e2e test needed only a small fix (the old check looked for a v2-style per-volume Mountpoint pod, gone in v3; now it reads the mounter pod's logs). Done.

- [ ] **10. Helm chart tests**
  - Render the chart in CI (`helm template` + `helm lint`) so a broken template is caught on every PR.
  - **Customer experience:** not customer-facing — a safety net so a broken chart never ships.
  - **Status:** a render test in CI (`helm template` + `helm lint`) so a broken template is caught on every change — in progress.

---

## Appendix A: kubeletPath test

Full e2e on a non-default kubelet root, using `kind`.

**What `kind` is:** "Kubernetes IN Docker" — a real Kubernetes cluster running inside a Docker container. Unlike managed EKS, it lets you change kubelet's `--root-dir`, so kubelet genuinely stores its files somewhere other than `/var/lib/kubelet`. That's why we use it here — testing a *non-default* kubelet root is the whole point, and EKS managed nodes can't relocate kubelet. The path-handling code is identical regardless of environment, so proving it on kind proves it everywhere.

Ran against pristine upstream tip `855fbe7` of `feature/daemonset-architecture`.

**Step 1 — Build the driver image from the branch.**
```
docker buildx build --load -f Dockerfile -t local/s3-csi-driver:kltest --platform linux/amd64 --target linux-amazon .
```
Result: `local/s3-csi-driver:kltest` built (there's no public image with daemonset-mode code).

**Step 2 — Create a kind cluster whose kubelet root is non-default** (`root-dir: /custom-kubelet`):
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: s3-klpath
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        root-dir: /custom-kubelet
```
Confirmed inside the node: `--root-dir=/custom-kubelet`, `/custom-kubelet/pods` exists, `/var/lib/kubelet` has no pod/plugin dirs.

**Step 3 — Give the driver AWS creds** (kind has no IRSA/instance profile): created a `aws-secret` in `kube-system` from `aws configure export-credentials`.

**Step 4 — Install the driver pointed at the custom root:**
```
helm upgrade --install s3-csi-driver -n kube-system ./charts/aws-mountpoint-s3-csi-driver \
  --set unsupportedDevInstall=true \
  --set image.repository=local/s3-csi-driver --set image.tag=kltest --set image.pullPolicy=Never \
  --set node.serviceAccount.create=true \
  --set node.kubeletPath=/custom-kubelet
```
Both daemonsets came up Ready.

**Step 5 — Run the e2e suite** (everything kind can run; cloud-identity/special-infra suites skipped):
```
SKIP='Credentials|IRSA|Pod Identity|Instance Profile|Express|Performance|Proxy|Headroom|Upgrade'
ginkgo -p --procs=4 -vv -timeout 45m --skip="$SKIP" -- \
  --bucket-region=us-east-1 --commit-id=kltest --bucket-prefix=s3klpath \
  --imds-available=false --cluster-name=s3-klpath --cluster-type=eksctl
```
We selected the specs from our own e2e suite that can actually run on `kind` — everything except the ones needing cloud identity or special infra (the `SKIP` list above). Result: **67 of 641 specs selected, all passed, 0 failed** — mount options, static provisioning, multi-volume, access modes, volume limits, and daemonset pod sharing (incl. a negative fsGroup-mismatch test). The skipped ones don't exercise `kubeletPath` anyway (Credentials/IRSA/Pod Identity/Instance Profile need cloud identity, S3 Express needs directory buckets, Proxy/Headroom/Performance/Upgrade need extra infra), and `kubeletPath` is pure path construction shared by all mounts — so the 67 that ran all mount/read/write through `/custom-kubelet`, which is the point.

**Step 6 — Prove the mounts live under the custom root** (inside the node): the CSI socket and driver mount/metadata dirs are all under `/custom-kubelet/...`, and `/var/lib/kubelet/plugins/s3.csi.aws.com/` has **none**.

**Conclusion:** v3 honors a non-default `node.kubeletPath` end-to-end. With the unit tests (custom root) and every EKS e2e (default root), kubeletPath is at parity with v2 — so no dedicated CI e2e for a custom root is needed (EKS can't relocate kubelet anyway; kind is the one thing that can prove it).

---

## Appendix B: Eviction / shutdown order test

### Three ways a node removes pods — and what protects the mounter in each
1. **`NoExecute` taint.** A taint has an **effect**: `NoSchedule` only blocks *placing new* pods on the node; `NoExecute` also **evicts pods already running** there if they don't tolerate it. So `NoExecute` is the eviction case. The mounter's default toleration tolerates every taint with **no time limit** → it's never evicted.
2. **`kubectl drain`.** `drain` (an admin emptying a node) **skips DaemonSet pods**, so the mounter is left running.
3. **Node graceful shutdown.** When a node is powered off cleanly — e.g. the instance is terminated for scale-in, node maintenance/upgrade, or a spot reclaim — the kubelet stops the pods in **priority order**; the mounter is `system-node-critical` (highest) → stopped **last**, after the workloads.

### What we tested (real EKS `mp-dev-cluster`, v3 daemonset mode)
Each test lists **what we did**, **what we saw**, and **what it means** (tied to the chart code).

**1. `NoExecute` taint — default config**
- Did: put a `NoExecute` "get off" taint on the node.
- Saw: the workload got a deletion timestamp immediately (`TaintManagerEviction`); the mounter never did.
- Means: the mounter's default toleration is `operator: Exists` with **no `tolerationSeconds`** (the `{{- if .Values.node.tolerateAllTaints }}` branch), so it tolerates every taint forever → never evicted.

**2. `kubectl drain` — default**
- Did: drained the node.
- Saw: workload evicted; mounter stayed Running (AGE unchanged, 0 restarts).
- Means: `drain` skips DaemonSet pods, and the mounter is `kind: DaemonSet`.

**3. 2-node drain — recovery**
- Did: scaled to 2 nodes, then drained the workload's node.
- Saw: the workload rescheduled to the other node, re-read a file written before the drain (data intact), and wrote a new one.
- Means: the mount recovers on another node — no data loss.

**4. Node graceful shutdown**
- Did: triggered an OS shutdown on the node via SSM (node kubelet config: `shutdownGracePeriod: 2m30s`, `shutdownGracePeriodCriticalPods: 30s`).
- Saw: the workload container terminated first (~+18s); the mounter was gone by ~+35s.
- Means: kubelet stops pods in priority order; the mounter is `system-node-critical`, so it's in the final phase → terminates after the workloads.

**5. `NoExecute` taint — `tolerateAllTaints: false`**
- Did: set the mounter to the non-default toleration set, then applied a `NoExecute` taint.
- Saw: `TaintManagerEviction` fired on the mounter at ~300s; a replacement pod appeared at +301s. (The live poller first looked like "still Running" because the DaemonSet instantly recreates an evicted pod — the timestamps confirm the 300s eviction.)
- Means: that config renders `{operator: Exists, effect: NoExecute, tolerationSeconds: 300}` (the `{{- else if .Values.node.defaultTolerations }}` branch) → a 300s eviction timer. The observed 300s **is** that value.

Cluster was restored afterward (scaled back to 1 node, taints removed, mounter tolerations reset to default, test namespace/PV/bucket deleted).

### Re-run on a 3-node cluster (2026-09-15) — all 5 cases, default install
Repeated the same cases on `mp-dev-cluster` scaled to **3 nodes**, with a real mounted workload (a `Deployment` + bucket) so eviction/recovery is observed on actual multi-node infra. Results matched, and the two order/recovery claims are now cleanly observed rather than inferred:

- **1. `NoExecute` taint (default):** workload evicted off the tainted node; the node's mounter + node pod stayed Running (unchanged pod, same age). The workload rescheduled to another node and came back Running (remounted).
- **2. `kubectl drain` (default):** drain output literally listed the mounter and node pod under `ignoring DaemonSet-managed Pods:` while it evicted the workload; the mounter stayed. Workload rescheduled to another node, Running.
- **3. Recovery across nodes (observed, 3 nodes):** in both 1 and 2 the `Deployment` moved to a *different* node and remounted — the multi-node reschedule the earlier single-node run couldn't show.
- **4. Graceful node shutdown (order from kubelet events):** node kubelet had `shutdownGracePeriod: 2m30s`, `shutdownGracePeriodCriticalPods: 30s`. Shut the node down via SSM; the kubelet `Killing` events show the order: workload `Stopping container app` at **23:14:59** (t+0s), mounter `Stopping container mounter` at **23:15:05** (t+6s) → **workload stopped first, mounter after** (the mounter is `system-node-critical`). Note: polling pod status couldn't capture the mounter's `finishedAt` (its status goes empty on the shutting-down node); the **event timestamps** are the reliable evidence, so the order is taken from those, not from the poll.
- **5. `NoExecute` taint, `tolerateAllTaints: false`:** on this run (feature tip) the mounter uses its **own** `tolerateAllTaints` knob, so I had to set both `node.tolerateAllTaints` and `daemonsetMounters[0].tolerateAllTaints` to `false`. The rendered mounter toleration became `{operator: Exists, effect: NoExecute, tolerationSeconds: 300}`; the mounter stayed Running through t+287s and was **gone by t+319s** → the ~300s timer. **Caveat:** needing to set the mounter's own knob is a **feature-tip artifact**, *not* the decided config — see the correction below.

> **Important — this run did NOT use the decided tolerations config.** It ran on feature/daemonset-architecture tip (commit `3857717`), where the mounter's tolerations come from its **own** `$mounter.tolerateAllTaints` knob. Our tolerations decision (item 2 / #948) is that the mounter **inherits `node.*`**. Cases 2–4 don't depend on this (drain skips DaemonSets; shutdown order is priority-based). Cases 1 and 5 do, so I re-ran them on the decided config — see below.

### Re-run on the DECIDED tolerations config (mounter inherits `node.*`)
Applied only the #948 tolerations change (mounter tolerations read `.Values.node.*`; nodeSelector/affinity left at feature tip — branch `test-eviction-decided-tolerations`) and re-ran the tolerations-dependent cases:
- **1. `NoExecute` taint (default):** mounter tolerations rendered `[{operator: Exists}]` (inherited from node's default `tolerateAllTaints: true`); after tainting, the mounter stayed Running — not evicted.
- **5. `NoExecute` taint, `tolerateAllTaints: false`:** set **only** `node.tolerateAllTaints=false` (left `daemonsetMounters[0].tolerateAllTaints: true`) — the mounter still rendered `{…NoExecute, tolerationSeconds: 300}` **purely by inheritance**. After tainting, the mounter was present at t+279s and **gone by t+310s** → the ~300s timer. So under the decided config **one knob** (`node.tolerateAllTaints`) drives both pods; the feature-tip "must also set the mounter's own knob" caveat does not apply.

Restored afterward (config reverted, taints removed, workload/PV/bucket deleted, scaled back to 2 nodes).

### Autoscaler test — EKS Auto Mode (Karpenter), decided tolerations config
Ran on a fresh **EKS Auto Mode** cluster (`mp-dev-eksauto`, K8s 1.36 — Auto Mode runs Karpenter underneath), driver installed the normal way in daemonset mode with the decided tolerations config, image pulled from the **private** ECR (built multi-arch so it runs on Auto Mode's arm64 and amd64 nodes). Goal: does the autoscaler ever remove the mounter before the workloads it serves?

- **Scale-up (100 mounted pods):** deployed a 100-replica Deployment (each mounting one shared S3 bucket, 250m CPU). Auto Mode provisioned a new node; the mounter DaemonSet **automatically landed on it** (`2/2`) and all 100 pods reached Running in ~72s — workloads never scheduled onto a node without a mounter.
- **Consolidation (scaled 100 → 8):** Karpenter replaced the large node with a smaller one. Observed order: it **brought up the new node with a mounter on it first** (`3/3`), then drained the old node — the 8 workloads were evicted and rescheduled onto the new node (brief downtime), **remounted** (the file written before the move read back intact), and the old node + its mounter were removed **together**, after the workloads had left.

**Conclusion:** under the autoscaler, the mounter is never torn down before its workloads. New nodes get a mounter before workloads arrive; a node being reclaimed is drained (workloads evicted first) before the node and its mounter go away; and mounts recover on the destination node. The brief downtime during a consolidation move is normal Karpenter pod-recreation, not driver-specific. Cluster/workload cleaned up afterward.

***

## Appendix C: Option B placement test (real EKS `mp-dev-cluster`, 2 nodes, v3 daemonset mode)

Tested the Option B chart change on `mp-dev-cluster` (**2× `c7a.xlarge`**, K8s 1.36). Chart change (`mounter-daemonset.yaml`): the mounter's `nodeSelector` merges `node.nodeSelector` **and** the mounter's own labels into one map (an AND). Installed the normal way (`MOUNTPOINT_CSI_DRIVER_MODE=daemonset ./dev/mp-dev.sh deploy-helm-chart`, using the chart's own `values.yaml`), edited `values.yaml` like a customer for the placement cases, and `kubectl label`'d nodes. Nodes: `node-1` = ...-29-71, `node-2` = ...-48-25.

### What we saw

**1. Baseline (default `values.yaml`, empty selectors)** — both DaemonSets on both nodes:
```
s3-csi-daemonset-mounter   DESIRED 2  READY 2   (one pod per node)
s3-csi-node                DESIRED 2  READY 2   (one pod per node)
mounter nodeSelector = {"kubernetes.io/os":"linux"}
```

**2. Subset — mounter narrows to a strict subset of nodes** (label only `node-1` `mp-test-profile=large`; mounter's own `nodeSelector={mp-test-profile: large}`; node selector left empty):
```
mounter nodeSelector = {"kubernetes.io/os":"linux","mp-test-profile":"large"}
s3-csi-daemonset-mounter   DESIRED 1  READY 1   -> node-1 only
s3-csi-node                DESIRED 2  READY 2   -> both nodes
```
→ `node-2` has a node pod but **no mounter** = the gap, on a real second node.

**3. The gap actually breaks a mount (observed, not inferred)** — a workload pinned to `node-2` (via `nodeName`) mounting the bucket got stuck `ContainerCreating`:
```
Warning FailedMount ... MountVolume.SetUp failed for volume "gap-pv":
  rpc error: code = Internal desc = Could not mount "<bucket>" at "...":
  connection to s3-csi-daemonset-mounter not yet established, allowing kubelet to retry
  NodePublishVolume: comm dir not yet discovered or stale.
```

**4. Filling the gap recovers it (observed)** — labelled `node-2` `large` too → the mounter DaemonSet scheduled a pod onto `node-2` (`DESIRED 2`), and the pinned workload mounted:
```
gap-app  1/1  Running  on node-2
$ kubectl exec gap-app -- sh -c 'echo gap-recovered > /data/gap.txt && cat /data/gap.txt'
gap-recovered
$ aws s3 ls s3://<bucket>/   -> gap.txt  (object landed in S3)
```

**5. Real mount on the baseline** — separately confirmed a busybox workload writes+reads through the mount and the object appears in S3 (`proof.txt`).

### Conclusion
**No bug attributable to Option B was observed.** On real 2-node infra it behaved exactly as designed in every case:
- the mounter runs only on the **intersection** of the node pod's nodes and its own labels — a strict subset (tests 1–2);
- normal mounts work under the change (test 5).

Tests 3–4 are **not** an Option B defect — they show what happens when you *deliberately* narrow the mounter off a node (test 3: a workload pinned to that uncovered node can't mount) and then cover it again (test 4: it mounts). That's the expected result of the narrowing config, and the same mismatch is already possible under today's independent-selector code; test 3 was set up by hand, not something Option B caused.

### Not caused by Option B — the `OnDelete` restart breaks live mounts
Redeploying restarts the mounter pod (`deploy-helm-chart` runs `kubectl delete po -l app=s3-csi-daemonset-mounter`, and the mounter is `updateStrategy: OnDelete`). Restarting the mounter kills every `mount-s3` process on that node, so **active** mounts on it drop (`Transport endpoint is not connected`) until the workload is recreated. This is the documented `OnDelete` tradeoff (the chart's own NOTES warn it "will temporarily break all active mounts"), independent of the placement change.

### Test-harness notes (mistakes, not driver behaviour)
- `helm --reuse-values` + `--set daemonsetMounters[0].<field>` replaces the whole first mounter entry, dropping `maxVolumesPerNode` → node pod fatals: `MAX_VOLUMES_PER_NODE must be a valid integer, got ""`. A `daemonsetMounters[]` entry must be complete (also `logLevel`, else the mounter gets `--v=` and exits 2). Editing the chart's `values.yaml` (the normal path) avoids both.

### Reproduce (exact steps)
Prereqs: `mp-dev-cluster` at **2 nodes**, `AWS_PROFILE` valid, `kubectl`/`helm`/`aws`/`eksctl` on PATH, run from repo root. `N1`/`N2` = the two node names (`kubectl get nodes`).
```bash
# 0. Ensure 2 nodes
eksctl scale nodegroup --cluster=mp-dev-cluster --name=ng-1 --nodes=2 --nodes-min=2 --nodes-max=2 --region=eu-north-1

# 1. Get the Option B chart (mounter nodeSelector = node.nodeSelector + its own, merged)
git checkout test-option-b-placement

# 2. Baseline install the normal way (uses the chart's own values.yaml)
MOUNTPOINT_CSI_DRIVER_MODE=daemonset ./dev/mp-dev.sh deploy-helm-chart
kubectl -n kube-system delete pod -l app=s3-csi-daemonset-mounter   # OnDelete: force re-render
kubectl -n kube-system get ds s3-csi-daemonset-mounter s3-csi-node \
  -o custom-columns=NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady
# expect: mounter 2/2, node 2/2  (Test 1)

# 3. Subset: label ONE node, give the mounter its own label via values.yaml, redeploy
kubectl label node "$N1" mp-test-profile=large --overwrite
#   edit charts/aws-mountpoint-s3-csi-driver/values.yaml -> daemonsetMounters[0].nodeSelector: {mp-test-profile: large}
MOUNTPOINT_CSI_DRIVER_MODE=daemonset ./dev/mp-dev.sh deploy-helm-chart
kubectl -n kube-system delete pod -l app=s3-csi-daemonset-mounter
# expect: mounter DESIRED 1 (N1 only), node DESIRED 2  -> N2 is the gap  (Test 2)

# 4. Gap breaks a mount: bucket + PV/PVC + a pod pinned to N2 (no mounter)
aws s3api create-bucket --bucket mp-optionb-test-$(aws sts get-caller-identity --query Account --output text) \
  --region eu-north-1 --create-bucket-configuration LocationConstraint=eu-north-1
#   apply a PV (csi driver s3.csi.aws.com, volumeHandle unique, volumeAttributes.bucketName=<bucket>),
#   its PVC, and a busybox Pod with spec.nodeName=$N2 mounting it at /data
kubectl describe pod <gap-pod> | grep FailedMount
# expect: "connection to s3-csi-daemonset-mounter not yet established"  (Test 3)

# 5. Recovery: cover N2 too
kubectl label node "$N2" mp-test-profile=large --overwrite
# mounter appears on N2; recreate the pod -> it mounts, read/write works, object shows in `aws s3 ls`  (Test 4)

# 6. Cleanup
kubectl delete pod,pvc,pv <yours>; aws s3 rm s3://<bucket> --recursive; aws s3api delete-bucket --bucket <bucket> --region eu-north-1
kubectl label node "$N1" mp-test-profile- ; kubectl label node "$N2" mp-test-profile-
git checkout feature/daemonset-architecture && MOUNTPOINT_CSI_DRIVER_MODE=daemonset ./dev/mp-dev.sh deploy-helm-chart
```

***

## Appendix D: Option A placement test (Rajdeepa's suggestion — real EKS `mp-dev-cluster`, 2 nodes, v3 daemonset mode)

Option A isn't in any branch and the chart currently forbids >1 mounter, so this was a **prototype** (branch `test-option-a-placement`, chart-only): `mounter-daemonset.yaml` now `range`s the `daemonsetMounters` list and renders one DaemonSet per entry (each with its own `nodeSelector` and a unique `mounter-profile` selector label); `node.yaml` generates the node pod's `nodeAffinity` as the **OR of every mounter's `nodeSelector`** (`node.nodeSelector` still ANDs on top). Installed on 2 nodes with two mounters: `large` (`nodeSelector mp-test-profile=large`) and `small` (`mp-test-profile=small`); `node-1` labelled `large`, `node-2` labelled `small`.

### What we saw

**A1. Two mounters, node pod on both nodes** (`node-1=large`, `node-2=small`):
```
s3-csi-daemonset-mounter-large   DESIRED 1  READY 1   -> node-1
s3-csi-daemonset-mounter-small   DESIRED 1  READY 1   -> node-2
s3-csi-node                      DESIRED 2  READY 2   -> both nodes
```
The generated node affinity was `OR( mp-test-profile=large , mp-test-profile=small )`, so the node pod ran on both, each covered by its matching mounter. (This is the heterogeneous case the current chart's single-entry `fail` forbids.)

**A2. The "win" — no orphan node pod** (removed `node-2`'s label so it matches *neither* profile):
```
s3-csi-node                      DESIRED 2 -> 1   (node pod gone from node-2)
s3-csi-daemonset-mounter-small   DESIRED 0
```
Because the node pod's affinity is the OR of the mounter selectors, a node matching no mounter gets **no node pod at all** — the gap is impossible by construction (Option A's advantage over B).

**A3. Real mounts work on both nodes** (re-labelled `node-2=small`, one workload pinned per node):
```
app-a1 on node-1 (large):  echo>/data/large.txt; cat -> from-large
app-a2 on node-2 (small):  echo>/data/small.txt; cat -> from-small
aws s3 ls -> large.txt, small.txt
```

### Conclusion
**No bug attributable to Option A was observed.** The prototype behaved as the suggestion describes: node pod = `node.nodeSelector AND (OR of mounters)`, so the node pod lands only where a mounter exists (A1–A2), and real mounts work with two different mounter profiles (A3). The cost is real but expected, not a bug: Option A required actual chart machinery (loop the mounter list, generate + own the node pod's `affinity`) that Option B doesn't. `maxVolumesPerNode` in the prototype still comes from entry 0 for all nodes (the known heterogeneous-limits gap) — not exercised here since both profiles used 4.

### Reproduce (exact steps)
Prereqs: same as Appendix C (2 nodes, tools on PATH, run from repo root). `N1`/`N2` = the two node names.
```bash
# 1. Get the Option A prototype (N mounters + node pod affinity = OR of mounter selectors)
git checkout test-option-a-placement

# 2. Label each node with a distinct profile
kubectl label node "$N1" mp-test-profile=large --overwrite
kubectl label node "$N2" mp-test-profile=small --overwrite

# 3. Install with TWO mounters (values file, since >1 entry). Each entry MUST be complete
#    (name, maxVolumesPerNode, logLevel, resources, tolerateAllTaints, nodeSelector):
cat > /tmp/optiona.yaml <<'YAML'
unsupportedDevInstall: true
image: {repository: <ACCT>.dkr.ecr.eu-north-1.amazonaws.com/mp-dev, pullPolicy: Always, tag: latest}
experimental: {mounterMode: daemonset}
daemonsetMounters:
  - {name: large, maxVolumesPerNode: 4, logLevel: 4, resources: {requests: {memory: "2Gi", cpu: "500m"}}, tolerateAllTaints: true, defaultTolerations: true, nodeSelector: {mp-test-profile: large}}
  - {name: small, maxVolumesPerNode: 4, logLevel: 4, resources: {requests: {memory: "1Gi", cpu: "250m"}}, tolerateAllTaints: true, defaultTolerations: true, nodeSelector: {mp-test-profile: small}}
YAML
helm upgrade --install aws-mountpoint-s3-csi-driver -n kube-system -f /tmp/optiona.yaml ./charts/aws-mountpoint-s3-csi-driver
kubectl -n kube-system delete pod -l app=s3-csi-daemonset-mounter
kubectl -n kube-system get ds -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver \
  -o custom-columns=NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady
kubectl -n kube-system get ds s3-csi-node -o custom-columns=NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled
# expect: mounter-large 1 (N1), mounter-small 1 (N2), node 2  (Test A1)
# check the generated node affinity is the OR:
kubectl -n kube-system get ds s3-csi-node -o jsonpath='{.spec.template.spec.affinity}' ; echo

# 4. The "win": make N2 match no mounter -> node pod leaves N2
kubectl label node "$N2" mp-test-profile-
kubectl -n kube-system get ds s3-csi-node -o custom-columns=NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled
# expect: node DESIRED drops 2 -> 1 (no orphan node pod on N2)  (Test A2)

# 5. Real mounts: re-label N2=small, bucket + a PV/PVC/pod pinned to each node, write+read, `aws s3 ls`  (Test A3)

# 6. Cleanup (same shape as Appendix C) + restore default chart:
git checkout feature/daemonset-architecture && MOUNTPOINT_CSI_DRIVER_MODE=daemonset ./dev/mp-dev.sh deploy-helm-chart
```
Note the prototype lives on branch `test-option-a-placement` (chart-only: `mounter-daemonset.yaml` ranges the list; `node.yaml` generates the OR affinity and drops the single-entry `fail`).
