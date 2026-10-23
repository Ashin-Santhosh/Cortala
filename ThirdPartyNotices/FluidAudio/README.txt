FluidAudio 0.17.7 (revision 503b4bd1bbf7220882de39fe8ae6716aae4132da)
https://github.com/FluidInference/FluidAudio

The app uses FluidAudio's offline segmentation/embedding/VBx diarization pipeline.
FluidAudio code is Apache 2.0; applicable upstream component licenses are preserved in Upstream/.
The optional NeMo text-processing trait and speech synthesis functionality are disabled.

CoreML model assets are downloaded separately on explicit user action from:
https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/7eab74f3463c736418d0eb10296261ae581146c9
Models-LICENSE.txt, NOTICE.md, and PROVENANCE.md preserve model publisher terms,
original pyannote/WeSpeaker attribution, and conversion provenance.
The app downloads only its allowlisted offline model files, each with a pinned SHA256.
