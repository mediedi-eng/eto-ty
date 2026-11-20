#ifndef ETOTY_BODY_RENDERER_H
#define ETOTY_BODY_RENDERER_H
#include <stddef.h>
#include <stdint.h>

// Mesh format is little endian ETM1, counts, xyz+normal float32, then triangle uint32s.
int body_render(const void *mesh, size_t length, uint8_t *rgba, uint8_t *regions,
                int width, int height, float yaw, float zoom, int selected);
#endif
