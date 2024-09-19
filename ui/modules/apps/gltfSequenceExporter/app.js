/* 
  Code modified from "BeamNG.drive/ui/modules/apps/Replay/app.js"
  and "BeamNG.drive/ui/modules/apps/threedexport/app.js"
 */

angular.module('beamng.apps')
  .directive('gltfSequenceExporter', ['$filter', '$log', '$state', '$rootScope', function ($filter, $log, $state, $rootScope) {
    return {
      templateUrl: '/ui/modules/apps/gltfSequenceExporter/app.html',
      replace: true,
      restrict: 'EA',
      scope: true,
      link: function (scope, element, attrs) {
        scope.Math = Math

        bngApi.engineLua('be:getFileStream():requestState()');

        scope.isOriginSet = false;

        scope.replayReady = false;

        scope.exportInProgress = false;
        scope.isVulkanEnabled = false;

        scope.positionSeconds;
        scope.totalSeconds;

        scope.currentFrame = 0;
        scope.totalFrames = 0;

        scope.frameRate;
        scope.frameStart;
        scope.frameEnd;

        bngApi.engineLua('gltfSequenceExporter_export.checkVulkan()', function (result) {
          scope.isVulkanEnabled = result;
        });

        scope.setOrigin = function () {
          bngApi.engineLua('gltfSequenceExporter_export.setOrigin()');
          scope.isOriginSet = true;
        };
        scope.clearOrigin = function () {
          bngApi.engineLua('gltfSequenceExporter_export.clearOrigin()');
          scope.isOriginSet = false;
        };

        scope.startExport = function () {
          scope.exportInProgress = true;
          if (scope.filenamePrefix === '') return;

          bngApi.engineLua(`gltfSequenceExporter_app.setStartFrame(${scope.frameStart})`);
          bngApi.engineLua(`gltfSequenceExporter_app.setEndFrame(${scope.frameEnd})`);
          bngApi.engineLua(`gltfSequenceExporter_app.setFilenamePrefix("${cleanPath(scope.filenamePrefix)}")`);
          bngApi.engineLua(`gltfSequenceExporter_app.setFrameRate(${scope.frameRate})`);
          bngApi.engineLua(`gltfSequenceExporter_app.setTotalReplaySeconds(${scope.totalSeconds})`);

          for (const prop of scope.boolProperties) {
            bngApi.engineLua(`gltfSequenceExporter_export.${prop.variable} = ${prop.value}`);
          }

          bngApi.engineLua("gltfSequenceExporter_app.startExport()");
        };

        scope.cancelExport = function () {
          bngApi.engineLua("gltfSequenceExporter_app.cancelExport()");
          scope.exportInProgress = false;
        };

        scope.$on('AnimationExportEnd', function (event, val) {
          scope.$evalAsync(function () {
            scope.exportInProgress = false;
          });
        });

        scope.$on('replayStateChanged', function (event, val) {
          scope.$evalAsync(function () {
            if (val.state == 'recording') {
              return
            }
            scope.positionSeconds = val.positionSeconds; // interpolated frame times
            scope.totalSeconds = val.totalSeconds;

            if (!scope.replayReady && val.loadedFile) {
              scope.onReplayLoaded();
            } else if (scope.replayReady && !val.loadedFile) {
              scope.onReplayUnloaded();
            }

            if (scope.replayReady) {
              scope.currentFrame = scope.positionSeconds * scope.frameRate;
              setFrameButtonIcons();
              setTimelineStyle();

              if (scope.exportInProgress) {
                setLoadingButtonStyle();
              }
            }
          });
        });

        scope.onReplayLoaded = function () {
          bngApi.engineLua("core_replay.pause(true)");
          bngApi.engineLua("core_replay.seek(0.0)");
          scope.setOrigin();

          scope.frameRate = 30;
          scope.frameStart = 1;
          updateFrameInfo();
          scope.frameEnd = Math.floor(scope.totalFrames);
          scope.replayReady = true;
        };

        scope.onReplayUnloaded = function () {
          scope.replayReady = false;
          scope.currentFrame = 0;
          scope.totalFrames = 0;
          scope.frameStart = 0;
          scope.frameEnd = 0;
          setTimelineStyle();
        };

        function updateFrameInfo() {
          scope.currentFrame = scope.positionSeconds * scope.frameRate;
          scope.totalFrames = scope.totalSeconds * scope.frameRate;
          scope.frameStart = clamp(scope.frameStart, 0, Math.floor(scope.totalFrames));
          scope.frameEnd = clamp(scope.frameEnd, scope.frameStart, Math.floor(scope.totalFrames));

          setFrameButtonIcons();
          setTimelineStyle();
        };

        scope.frameProperties = {
          frameRate: {
            userValue: 30,
            min: 1,
            max: Infinity,
            label: "Frame Rate",
            tooltip: "Frame rate of the animation in frames per second.",
          },
          frameStart: {
            userValue: undefined,
            min: 0,
            get max() {
              return Math.min(scope.frameEnd, Math.floor(scope.totalFrames));
            },
            label: "Frame Start",
            tooltip: "First frame of the animation.",
          },
          frameEnd: {
            userValue: undefined,
            get min() {
              return scope.frameStart;
            },
            get max() {
              return Math.floor(scope.totalFrames);
            },
            label: "End",
            tooltip: "Final frame of the animation.",
          },
        };

        scope.formSubmit = function () {
          if (scope.framePropertiesForm.$valid) {
            updateMaster();
          }
        }

        function updateMaster() {
          scope.frameRate = scope.frameProperties.frameRate.userValue;
          scope.frameStart = scope.frameProperties.frameStart.userValue;
          scope.frameEnd = scope.frameProperties.frameEnd.userValue;
          scope.framePropertiesForm.$setPristine(true);
        };

        scope.keyPressed = function ($event) {
          switch ($event.key) {
            case 'Enter':
              if (scope.framePropertiesForm.$valid) {
                $event.target.blur();
              }
              break;
          }
        };

        scope.inputClicked = function ($event) {
          if (scope.framePropertiesForm.$valid && scope.framePropertiesForm.$dirty) {
            scope.formSubmit();
          }
        };

        scope.inputBlurred = function ($event) {
          if (scope.framePropertiesForm.$valid && scope.framePropertiesForm.$dirty) {
            scope.formSubmit();
          }
        };

        scope.selectInputText = function ($event) {
          $event.target.select();
        };

        scope.$watch('frameStart', function () {
          if (scope.replayReady) {
            setFrameButtonIcons();
            setTimelineStyle()
            if (scope.framePropertiesForm && scope.framePropertiesForm.frameStart) {
              if (scope.framePropertiesForm.frameStart.$pristine) {
                scope.frameProperties.frameStart.userValue = scope.frameStart;
              }
            }
          }
        });
        scope.$watch('frameEnd', function () {
          if (scope.replayReady) {
            setFrameButtonIcons();
            setTimelineStyle()
            if (scope.framePropertiesForm && scope.framePropertiesForm.frameEnd) {
              if (scope.framePropertiesForm.frameEnd.$pristine) {
                scope.frameProperties.frameEnd.userValue = scope.frameEnd;
              }
            }
          }
        });
        scope.$watch('frameRate', function () {
          if (scope.replayReady) {
            updateFrameInfo();
            setTimelineStyle();
            if (scope.framePropertiesForm && scope.framePropertiesForm.frameRate) {
              if (scope.framePropertiesForm.frameRate.$pristine) {
                scope.frameProperties.frameRate.userValue = scope.frameRate;
              }
            }
          }
        });

        scope.boolProperties = [
          { label: "Include", name: "Normals", value: true, variable: "exportNormals", tooltip: "Export normal data.", },
          { label: "", name: "UVs", value: true, variable: "exportTexCoords", tooltip: "Export UV texture coordinates.", },
          { label: "", name: "Tangents", value: false, variable: "exportTangents", tooltip: "Export geometry tangent data.", },
          { label: "", name: "Vertex Colors", value: false, variable: "exportColors", tooltip: "Export geometry vertex color data.", },
          { label: "", name: "JBeam", value: false, variable: "exportBeams", tooltip: "Export beam length and positions data for parts. Unused by glTF.", },
          { label: "", name: "Extras", value: false, variable: "exportExtras", tooltip: "Export extra BeamNG-specific data such as materials and direction vectors. Unused by glTF.", },
          { label: "File", name: "Binary Format", value: true, variable: "gltfBinaryFormat", tooltip: "Export to binary glTF .glb format instead of plaintext .gltf.", },
          { label: "", name: "Embed Buffers", value: true, variable: "embedBuffers", tooltip: "Embed the data in a single file per frame. If unchecked, export data as multiple .bin files per frame.", },
          { label: "", name: "External Textures", value: true, variable: "externalTextures", tooltip: "Use a reference to the texture data location on disk rather than re-exporting texture data for each frame.", },
        ];

        scope.filenamePrefix;
        scope.getNewFilenamePrefix = function () {
          bngApi.engineLua(`gltfSequenceExporter_app.suggestFilenamePrefix()`, function (data) {
            scope.filenamePrefix = data;
          });
        };
        scope.getNewFilenamePrefix();

        scope.$on('VehicleChange', function () {
          scope.getNewFilenamePrefix();
        });

        scope.$on('VehicleFocusChanged', function () {
          scope.getNewFilenamePrefix();
        });

        scope.openDirectory = function () {
          bngApi.engineLua(`gltfSequenceExporter_app.openDirectory("${cleanPath(scope.filenamePrefix)}")`);
        };

        scope.loadingButtonStyle;
        function setLoadingButtonStyle() {
          var percent = ((scope.currentFrame - scope.frameStart) / (scope.animLength - 1) * 100) + '%';
          scope.loadingButtonStyle = {
            'background-image': `linear-gradient(to right, var(--loadingFg) ${percent}, var(--loadingBg) ${percent})`,
          };
        };

        function setFrameButtonIcons() {
          let currentFrame = Math.floor(scope.currentFrame);

          let filled = currentFrame >= scope.frameStart && currentFrame <= scope.frameEnd;
          let range = currentFrame > scope.frameStart && currentFrame < scope.frameEnd;
          let barLeft = currentFrame <= scope.frameStart && !range;
          let barRight = currentFrame >= scope.frameEnd && !range;

          scope.frameButtonIconL = makeIconSrc(filled, barLeft);
          scope.frameButtonIconR = makeIconSrc(filled, barRight);

          function makeIconSrc(filled, bar) {
            let variant = bar ? "impulse" : "constant";
            let num = filled ? "1" : "2";
            return `editor_fg_type_flow_${variant}_${num}`;
          }
        }

        scope.timelineStyle;
        function setTimelineStyle() {
          let start = (scope.frameStart / scope.totalFrames) * 100;
          start = clamp(start, 0, 100);
          let end = (scope.frameEnd / scope.totalFrames) * 100;
          end = clamp(end, 0, 100);
          scope.timelineStyle = {
            background: `linear-gradient(to right, transparent ${start}%, var(--frame-range-fg) ${start}%, var(--frame-range-fg) ${end}%, transparent ${end}%)`,
          };
        };

        function clamp(val, min, max) {
          return Math.min(Math.max(val, min), max);
        };

        function cleanPath(path) {
          return path.replace(/[^\/\.\-\(\)\w\s]/g, '_');
        }

        scope.luaSetDebug = function () {
          bngApi.engineLua("gltfSequenceExporter_app.DEBUG_DRY_RUN_EXPORT = " + !!scope.dryRunExport);
          bngApi.engineLua("gltfSequenceExporter_app.DEBUG_FRAME_PACING = " + !!scope.logFramePacing);
        };

      }
    };
  }]);

angular.module('beamng.apps')
  .filter('integer', function () {
    return function (num) {
      return (num == null) ? num : Math.floor(num);
    };
  })