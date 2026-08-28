#ifndef AMADEUS_CORE_H_
#define AMADEUS_CORE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t amadeus_core_version(void);
int32_t amadeus_activity_classify(const char* app_name,
                                  uint64_t idle_seconds,
                                  uint64_t idle_threshold,
                                  const char* excluded_apps);
uint32_t amadeus_focus_score(uint64_t active_seconds,
                             uint64_t idle_seconds,
                             uint32_t switches);

#ifdef __cplusplus
}
#endif

#endif  // AMADEUS_CORE_H_
