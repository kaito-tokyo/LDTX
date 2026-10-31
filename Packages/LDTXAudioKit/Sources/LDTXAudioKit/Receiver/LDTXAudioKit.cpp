// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

#include <LDTXAudioKit/WorkspaceAudioEngine.h>
#include "../../../../../Sources/LDTXAudioEngine/AudioMixEngine.cpp"
#include "../../../../../Sources/LDTXAudioEngine/WorkspaceAudioEngine.cpp"

extern "C" {

const char *LDTXAudioKitVersion(void) { return "0.1"; }

LDTXAudioKitReceiver *LDTXAudioKitCreate(bool hardware) { return LDTXAudioCreate(hardware); }
void LDTXAudioKitDestroy(LDTXAudioKitReceiver *e) { LDTXAudioDestroy(e); }
void LDTXAudioKitSetErrorHandler(LDTXAudioKitReceiver *e, LDTXAudioKitErrorHandler h, void *c) {
  LDTXAudioSetErrorHandler(e, h, c);
}
LDTXAudioKitID LDTXAudioKitAddInput(LDTXAudioKitReceiver *e, const char *u, uint32_t k, double r, uint32_t c) {
  return LDTXAudioAddInput(e, u, k, r, c);
}
bool LDTXAudioKitHasActiveInput(LDTXAudioKitReceiver *e, const char *u) { return LDTXAudioHasActiveInput(e, u); }
void LDTXAudioKitRemoveInput(LDTXAudioKitReceiver *e, LDTXAudioKitID i) { LDTXAudioRemoveInput(e, i); }
LDTXAudioKitID LDTXAudioKitCreateBus(LDTXAudioKitReceiver *e) { return LDTXAudioCreateBus(e); }
void LDTXAudioKitConfigureBus(LDTXAudioKitReceiver *e, LDTXAudioKitID b, const LDTXAudioKitRoute *r, uint32_t n, float g) {
  LDTXAudioConfigureBus(e, b, reinterpret_cast<const LDTXAudioRoute *>(r), n, g);
}
void LDTXAudioKitRemoveBus(LDTXAudioKitReceiver *e, LDTXAudioKitID b) { LDTXAudioRemoveBus(e, b); }
void LDTXAudioKitUpdateMonitorValues(LDTXAudioKitReceiver *e, const LDTXAudioKitRoute *r, uint32_t n, float g) {
  LDTXAudioUpdateMonitorValues(e, reinterpret_cast<const LDTXAudioRoute *>(r), n, g);
}
void LDTXAudioKitConfigureMonitor(LDTXAudioKitReceiver *e, const char *u, const LDTXAudioKitRoute *r, uint32_t n, float g) {
  LDTXAudioConfigureMonitor(e, u, reinterpret_cast<const LDTXAudioRoute *>(r), n, g);
}
LDTXAudioKitID LDTXAudioKitSubscribe(LDTXAudioKitReceiver *e, LDTXAudioKitID s, bool raw, LDTXAudioKitSampleHandler h, void *c) {
  return LDTXAudioSubscribe(e, s, raw, h, c);
}
void LDTXAudioKitUnsubscribe(LDTXAudioKitReceiver *e, LDTXAudioKitID s) { LDTXAudioUnsubscribe(e, s); }
float LDTXAudioKitConsumePeak(LDTXAudioKitReceiver *e, LDTXAudioKitID s, bool raw) { return LDTXAudioConsumePeak(e, s, raw); }
LDTXAudioKitStatistics LDTXAudioKitGetStatistics(LDTXAudioKitReceiver *e, LDTXAudioKitID s) {
  const auto v = LDTXAudioGetStatistics(e, s);
  return {v.receivedFrames, v.droppedFrames, v.invalidTimestamps, v.renderErrors, v.generation,
          v.inputBufferFrames, v.outputBufferFrames};
}
void LDTXAudioKitStop(LDTXAudioKitReceiver *e, LDTXAudioKitCompletion h, void *c) { LDTXAudioStop(e, h, c); }
bool LDTXAudioKitSubmitPCM(LDTXAudioKitReceiver *e, LDTXAudioKitID s, const AudioBufferList *b, const AudioTimeStamp *t) {
  return LDTXAudioSubmitPCM(e, s, b, t);
}
void LDTXAudioKitAdvance(LDTXAudioKitReceiver *e, uint64_t n) { LDTXAudioAdvance(e, n); }

}
