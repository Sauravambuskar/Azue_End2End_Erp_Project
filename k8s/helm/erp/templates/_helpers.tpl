{{- define "erp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "erp.labels" -}}
app.kubernetes.io/name: {{ include "erp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: contoso-erp
environment: {{ .Values.config.env }}
{{- end -}}

{{- define "erp.componentLabels" -}}
{{ include "erp.labels" . }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Hardened pod security context, applied to every workload.
Matches the "restricted" Pod Security Standard and the Azure Policy /
Gatekeeper constraints in policy/.
*/}}
{{- define "erp.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "erp.containerSecurityContext" -}}
allowPrivilegeEscalation: false
privileged: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
Shared environment for anything that talks to PostgreSQL.
Note there is NO password: ERP_DB_USE_MANAGED_IDENTITY makes the app fetch an
Entra token through workload identity at connect time.
*/}}
{{- define "erp.dbEnv" -}}
- name: ERP_DB_HOST
  valueFrom:
    configMapKeyRef:
      name: {{ include "erp.name" . }}-config
      key: db_host
- name: ERP_DB_PORT
  valueFrom:
    configMapKeyRef:
      name: {{ include "erp.name" . }}-config
      key: db_port
- name: ERP_DB_NAME
  valueFrom:
    configMapKeyRef:
      name: {{ include "erp.name" . }}-config
      key: db_name
- name: ERP_DB_SSLMODE
  valueFrom:
    configMapKeyRef:
      name: {{ include "erp.name" . }}-config
      key: db_sslmode
- name: ERP_DB_USE_MANAGED_IDENTITY
  value: {{ .Values.config.db.useManagedIdentity | quote }}
{{- end -}}

{{- define "erp.image" -}}
{{- printf "%s/%s:%s" .registry .repository .tag -}}
{{- end -}}
