// jetson-device-plugin — minimal CDI-native GPU device plugin for Jetson Orin
//
// Exposes nvidia.com/gpu: 1 as a Kubernetes extended resource.
// On Allocate(), returns CDIDevices: [{Name: "nvidia.com/gpu=0"}] so that
// containerd 2.x reads /var/run/cdi/nvidia-jetson.yaml and automatically
// injects all nvgpu + nvhost device nodes, JetPack r36.5 lib bind-mount,
// and LD_LIBRARY_PATH into the container — no hostPath mounts needed.
//
// GPU presence is detected by /dev/nvgpu/igpu0/ctrl (nvgpu 5.x, NVHOST=n).
//
// Build (linux/arm64):
//   docker buildx build --platform linux/arm64 -t REGISTRY/jetson-device-plugin:v1.0.0 .
package main

import (
	"context"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

const (
	resourceName = "nvidia.com/gpu"
	devicePath   = "/dev/nvgpu/igpu0/ctrl"
	cdiDevice    = "nvidia.com/gpu=0"
	kubeletSock  = "/var/lib/kubelet/device-plugins/kubelet.sock"
	pluginSock   = "/var/lib/kubelet/device-plugins/jetson-device-plugin.sock"
	pollInterval = 30 * time.Second
)

// JetsonPlugin implements the Kubernetes Device Plugin gRPC interface.
type JetsonPlugin struct {
	v1beta1.UnimplementedDevicePluginServer
}

func gpuHealth() string {
	if _, err := os.Stat(devicePath); err == nil {
		return v1beta1.Healthy
	}
	return v1beta1.Unhealthy
}

// GetDevicePluginOptions returns plugin options (no special options needed).
func (p *JetsonPlugin) GetDevicePluginOptions(_ context.Context, _ *v1beta1.Empty) (*v1beta1.DevicePluginOptions, error) {
	return &v1beta1.DevicePluginOptions{}, nil
}

// ListAndWatch reports one GPU device and re-reports health every pollInterval.
func (p *JetsonPlugin) ListAndWatch(_ *v1beta1.Empty, s v1beta1.DevicePlugin_ListAndWatchServer) error {
	devices := []*v1beta1.Device{{ID: "igpu0", Health: v1beta1.Healthy}}
	for {
		devices[0].Health = gpuHealth()
		if err := s.Send(&v1beta1.ListAndWatchResponse{Devices: devices}); err != nil {
			return err
		}
		time.Sleep(pollInterval)
	}
}

// GetPreferredAllocation is optional — not needed for single-GPU nodes.
func (p *JetsonPlugin) GetPreferredAllocation(_ context.Context, _ *v1beta1.PreferredAllocationRequest) (*v1beta1.PreferredAllocationResponse, error) {
	return &v1beta1.PreferredAllocationResponse{}, nil
}

// Allocate returns:
//   - A sentinel DeviceSpec for /dev/nvgpu/igpu0/ctrl so kubelet tracks the device.
//   - CDIDevices: [{Name: "nvidia.com/gpu=0"}] so containerd 2.x reads
//     /var/run/cdi/nvidia-jetson.yaml and injects all GPU devices + libs.
func (p *JetsonPlugin) Allocate(_ context.Context, r *v1beta1.AllocateRequest) (*v1beta1.AllocateResponse, error) {
	var responses []*v1beta1.ContainerAllocateResponse
	for range r.ContainerRequests {
		responses = append(responses, &v1beta1.ContainerAllocateResponse{
			Devices: []*v1beta1.DeviceSpec{{
				ContainerPath: devicePath,
				HostPath:      devicePath,
				Permissions:   "rw",
			}},
			// CDI injection: containerd reads the spec at /var/run/cdi/nvidia-jetson.yaml
			// and injects all nvgpu + nvhost devices, tegra lib bind-mount, LD_LIBRARY_PATH.
			CDIDevices: []*v1beta1.CDIDevice{{
				Name: cdiDevice,
			}},
		})
	}
	return &v1beta1.AllocateResponse{ContainerResponses: responses}, nil
}

// PreStartContainer is a no-op for this plugin.
func (p *JetsonPlugin) PreStartContainer(_ context.Context, _ *v1beta1.PreStartContainerRequest) (*v1beta1.PreStartContainerResponse, error) {
	return &v1beta1.PreStartContainerResponse{}, nil
}

func main() {
	log.SetFlags(log.Ltime | log.Lshortfile)
	log.Printf("jetson-device-plugin starting: resource=%s cdi=%s", resourceName, cdiDevice)

	// Clean up any stale socket from previous run.
	_ = os.Remove(pluginSock)

	lis, err := net.Listen("unix", pluginSock)
	if err != nil {
		log.Fatalf("listen %s: %v", pluginSock, err)
	}

	srv := grpc.NewServer()
	v1beta1.RegisterDevicePluginServer(srv, &JetsonPlugin{})
	go func() {
		if err := srv.Serve(lis); err != nil {
			log.Fatalf("gRPC server error: %v", err)
		}
	}()
	log.Printf("gRPC server listening on %s", pluginSock)

	// Register with kubelet.
	conn, err := grpc.NewClient(
		"unix://"+kubeletSock,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		log.Fatalf("dial kubelet: %v", err)
	}
	defer conn.Close()

	regClient := v1beta1.NewRegistrationClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := regClient.Register(ctx, &v1beta1.RegisterRequest{
		Version:      v1beta1.Version,
		Endpoint:     filepath.Base(pluginSock),
		ResourceName: resourceName,
	}); err != nil {
		log.Fatalf("register with kubelet: %v", err)
	}
	log.Printf("registered with kubelet as %s", resourceName)

	// Block until signal.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("shutting down")
	srv.GracefulStop()
}
