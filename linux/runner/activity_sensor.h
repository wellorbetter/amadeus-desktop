#ifndef AMADEUS_ACTIVITY_SENSOR_H_
#define AMADEUS_ACTIVITY_SENSOR_H_

#include <cstdint>
#include <string>

namespace amadeus {

// The complete Linux observation payload. It intentionally has no window
// title, executable path, screenshot, or input-content field.
struct ActivitySample {
  std::string app_name;
  std::string app_id;
  std::uint64_t idle_seconds = 0;
};

// Reads the active process identity and global idle duration on X11. Wayland
// does not provide a compositor-independent global observation API, so it
// fails closed instead of falling back to invasive desktop scraping.
bool ReadActivitySample(ActivitySample* sample,
                        std::string* error_code,
                        std::string* error_message);

}  // namespace amadeus

#endif  // AMADEUS_ACTIVITY_SENSOR_H_
