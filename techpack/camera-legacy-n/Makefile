ifeq ($(CONFIG_MSMB_CAMERA_LEGACY_N),y)
ccflags-y += -Itechpack/camera-legacy-n
ccflags-y += -Itechpack/camera-legacy-n/sensor
ccflags-y += -Itechpack/camera-legacy-n/codecs
ccflags-y += -Itechpack/camera-legacy-n/isps
ccflags-y += -Itechpack/camera-legacy-n/pproc
ccflags-y += -Itechpack/camera-legacy-n/msm_vb2
ccflags-y += -Itechpack/camera-legacy-n/camera
ccflags-y += -Itechpack/camera-legacy-n/jpeg_10
ccflags-y += -Itechpack/camera-legacy-n/jpeg_dma
ccflags-y += -Itechpack/camera-legacy-n/fd
ccflags-y += -Itechpack/camera-legacy-n/common

# Use USERINCLUDE when you must reference the UAPI directories only.
USERINCLUDE     += \
                -I$(srctree)/techpack/camera-legacy-n/include/uapi \

# Use LINUXINCLUDE when you must reference the include/ directory.
# Needed to be compatible with the O= option
LINUXINCLUDE    += \
                -I$(srctree)/techpack/camera-legacy-n/include \
                -I$(srctree)/techpack/camera-legacy-n/include/uapi

obj-$(CONFIG_MSMB_CAMERA_LEGACY_N) += init.o

obj-$(CONFIG_MSMB_CAMERA) += common/
obj-$(CONFIG_MSMB_CAMERA) += msm.o
obj-$(CONFIG_MSMB_CAMERA) += camera/
obj-$(CONFIG_MSMB_CAMERA) += msm_vb2/
obj-$(CONFIG_MSMB_CAMERA) += sensor/
obj-$(CONFIG_MSMB_CAMERA) += pproc/
obj-$(CONFIG_MSMB_CAMERA) += isp/
obj-$(CONFIG_MSMB_CAMERA) += ispif/
obj-$(CONFIG_MSMB_JPEG) += jpeg_10/
obj-$(CONFIG_MSM_JPEGDMA) += jpeg_dma/
obj-$(CONFIG_MSMB_CAMERA) += msm_buf_mgr/
obj-$(CONFIG_MSM_FD) += fd/
else
ccflags-y := -Wno-unused-function
obj-y := stub.o
endif
