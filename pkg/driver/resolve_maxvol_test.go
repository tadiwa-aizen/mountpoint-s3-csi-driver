package driver

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestResolveMaxVolumesPerNode(t *testing.T) {
	node := &corev1.Node{ObjectMeta: metav1.ObjectMeta{
		Name:   "node-a",
		Labels: map[string]string{"node.kubernetes.io/instance-type": "m5.large"},
	}}

	t.Run("by-label match returns that type's limit", func(t *testing.T) {
		cs := fake.NewSimpleClientset(node)
		t.Setenv("MAX_VOLUMES_PER_NODE_BY_LABEL", `{"c7a.xlarge":10,"m5.large":3}`)
		t.Setenv("MAX_VOLUMES_PER_NODE_LABEL_KEY", "node.kubernetes.io/instance-type")
		t.Setenv("CSI_NODE_NAME", "node-a")
		got, err := resolveMaxVolumesPerNode(context.Background(), cs)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 3 {
			t.Fatalf("want 3, got %d", got)
		}
	})

	t.Run("fail-closed when node type not in map", func(t *testing.T) {
		cs := fake.NewSimpleClientset(node)
		t.Setenv("MAX_VOLUMES_PER_NODE_BY_LABEL", `{"c7a.xlarge":10,"r5.4xlarge":40}`)
		t.Setenv("MAX_VOLUMES_PER_NODE_LABEL_KEY", "node.kubernetes.io/instance-type")
		t.Setenv("CSI_NODE_NAME", "node-a")
		if _, err := resolveMaxVolumesPerNode(context.Background(), cs); err == nil {
			t.Fatalf("expected fail-closed error for unmapped type, got nil")
		}
	})

	t.Run("scalar fallback when no map", func(t *testing.T) {
		cs := fake.NewSimpleClientset(node)
		t.Setenv("MAX_VOLUMES_PER_NODE", "7")
		got, err := resolveMaxVolumesPerNode(context.Background(), cs)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 7 {
			t.Fatalf("want 7, got %d", got)
		}
	})
}
