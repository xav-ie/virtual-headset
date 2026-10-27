// Minimal LADSPA 1.1 plugin ABI: just what a host needs.
typedef float LADSPA_Data;
typedef void *LADSPA_Handle;
typedef int LADSPA_PortDescriptor;
enum { LADSPA_PORT_INPUT = 0x1, LADSPA_PORT_OUTPUT = 0x2, LADSPA_PORT_CONTROL = 0x4, LADSPA_PORT_AUDIO = 0x8 };
typedef struct { int HintDescriptor; LADSPA_Data LowerBound; LADSPA_Data UpperBound; } LADSPA_PortRangeHint;
typedef struct LADSPA_Descriptor {
  unsigned long UniqueID;
  const char *Label;
  int Properties;
  const char *Name, *Maker, *Copyright;
  unsigned long PortCount;
  const LADSPA_PortDescriptor *PortDescriptors;
  const char *const *PortNames;
  const LADSPA_PortRangeHint *PortRangeHints;
  void *ImplementationData;
  LADSPA_Handle (*instantiate)(const struct LADSPA_Descriptor *, unsigned long SampleRate);
  void (*connect_port)(LADSPA_Handle, unsigned long Port, LADSPA_Data *);
  void (*activate)(LADSPA_Handle);
  void (*run)(LADSPA_Handle, unsigned long SampleCount);
  void (*run_adding)(LADSPA_Handle, unsigned long);
  void (*set_run_adding_gain)(LADSPA_Handle, LADSPA_Data);
  void (*deactivate)(LADSPA_Handle);
  void (*cleanup)(LADSPA_Handle);
} LADSPA_Descriptor;
typedef const LADSPA_Descriptor *(*LADSPA_Descriptor_Function)(unsigned long Index);
