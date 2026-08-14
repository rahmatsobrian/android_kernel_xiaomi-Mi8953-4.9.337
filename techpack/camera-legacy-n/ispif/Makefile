ccflags-y += -Itechpack/camera-legacy-n
ccflags-y += -Itechpack/camera-legacy-n/sensor/io
ccflags-y += -Itechpack/camera-legacy-n/common/
ifeq ($(CONFIG_MSM_ISP_V1),y)
obj-$(CONFIG_MSM_CSID) += msm_ispif_32.o
else
obj-$(CONFIG_MSM_CSID) += msm_ispif.o
endif