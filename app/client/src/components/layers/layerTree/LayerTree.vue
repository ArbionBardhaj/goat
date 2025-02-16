<template>
  <v-flex xs12 sm8 md4>
    <v-divider></v-divider>
    <vue-scroll>
      <v-tabs-items v-model="layerTabIndex">
        <v-tab-item :eager="true">
          <v-expansion-panels accordion multiple>
            <v-expansion-panel
              v-for="(layerGroupValue, layerGroupKey) in layerGroups"
              :key="layerGroupKey"
              expand
            >
              <v-expansion-panel-header
                class="elevation-2"
                expand-icon=""
                v-slot="{ open }"
              >
                <v-layout row wrap align-center>
                  <v-flex xs1>
                    <v-icon small>{{
                      getLayerGroupIcon(layerGroupKey)
                    }}</v-icon>
                  </v-flex>
                  <v-flex xs10 class="light-text" style="font-size:medium;">
                    <div>
                      <b>{{ translate("layerGroup", layerGroupKey) }}</b>
                    </div>
                  </v-flex>
                  <v-flex xs1>
                    <v-icon v-html="open ? 'remove' : 'add'"></v-icon>
                  </v-flex>
                </v-layout>
              </v-expansion-panel-header>
              <v-expansion-panel-content>
                <!-- LAYERS -->
                <v-expansion-panels readonly>
                  <v-expansion-panel
                    v-for="(layer, i) in layerGroupValue"
                    :key="i"
                    class="layer-row"
                    :class="{
                      'expansion-panel__container--active':
                        layer.get('showOptions') === true
                    }"
                  >
                    <v-expansion-panel-header expand-icon="" v-slot="{}">
                      <v-layout row class="pl-1" wrap align-center>
                        <v-flex class="checkbox" xs1>
                          <v-simple-checkbox
                            :color="appColor.secondary"
                            :value="layer.getVisible()"
                            @input="
                              toggleLayerVisibility(layer, layerGroupValue)
                            "
                          ></v-simple-checkbox>
                        </v-flex>
                        <v-flex xs10 class="light-text">
                          <h4 class="pl-2">
                            {{ translate("layerName", layer.get("name")) }}
                          </h4>
                        </v-flex>
                        <v-flex xs1>
                          <v-icon
                            v-show="
                              layer.getVisible() &&
                                layer.get('name') !== 'study_area'
                            "
                            small
                            style="width: 30px; height: 30px;"
                            v-html="
                              layer.get('showOptions')
                                ? 'fas fa-chevron-down'
                                : 'fas fa-chevron-up'
                            "
                            :class="{
                              'expansion-panel__container--active': layer.get(
                                'showOptions'
                              )
                            }"
                            @click.stop="toggleLayerOptions(layer)"
                          ></v-icon>
                        </v-flex>
                      </v-layout>
                    </v-expansion-panel-header>
                    <v-card
                      class="pt-2"
                      v-show="
                        layer.getVisible() &&
                          layer.get('showOptions') === true &&
                          layer.get('name') !== 'study_area'
                      "
                      style="background-color: white;"
                      transition="slide-y-reverse-transition"
                    >
                      <InLegend :layer="layer"></InLegend>
                      <v-layout row style="width:100%;padding-left: 10px;">
                        <v-flex
                          class="xs2"
                          style="text-align:center;"
                          v-if="
                            ['VECTORTILE', 'VECTOR', 'MVT', 'GEOBUF'].includes(
                              layer.get('type').toUpperCase()
                            )
                          "
                        >
                          <v-icon
                            v-ripple
                            style="color:#B0B0B0;margin-top:3px;cursor:pointer"
                            dark
                            @click="openStyleDialog(layer)"
                          >
                            fas fa-cog
                          </v-icon>
                        </v-flex>
                        <v-flex
                          :class="{
                            xs10:
                              [
                                'VECTORTILE',
                                'VECTOR',
                                'MVT',
                                'GEOBUF'
                              ].includes(layer.get('type').toUpperCase()) ==
                              true,
                            xs12: false
                          }"
                        >
                          <v-slider
                            :value="layer.getOpacity()"
                            class="mx-5"
                            step="0.05"
                            min="0"
                            max="1"
                            @input="changeLayerOpacity($event, layer)"
                            :label="$t('layerTree.settings.transparency')"
                            :color="appColor.secondary"
                          ></v-slider>
                        </v-flex>
                      </v-layout>
                    </v-card>
                  </v-expansion-panel>
                </v-expansion-panels>
                <!-- ---- -->
              </v-expansion-panel-content>
            </v-expansion-panel>
          </v-expansion-panels>
        </v-tab-item>
        <v-tab-item :eager="true">
          <layer-order
            :map="map"
            :translate="translate"
            :toggleLayerOptions="toggleLayerOptions"
            :changeLayerOpacity="changeLayerOpacity"
          ></layer-order>
        </v-tab-item>
      </v-tabs-items>
    </vue-scroll>
    <span v-if="styleDialogStatus">
      <style-dialog
        :item="currentItem"
        :translate="translate"
        :key="styleDialogKey"
        :styleDialogStatus="styleDialogStatus"
      >
      </style-dialog>
    </span>
  </v-flex>
</template>

<script>
import { Mapable } from "../../../mixins/Mapable";
import { mapGetters } from "vuex";
import { mapFields } from "vuex-map-fields";

import { EventBus } from "../../../EventBus";
import Legend from "../../viewer/ol/controls/Legend";
import InLegend from "../../viewer/ol/controls/InLegend";
import LayerOrder from "../layerOrder/LayerOrder";
import StyleDialog from "../changeStyle/StyleDialog";
export default {
  mixins: [Mapable, Legend],
  data: () => ({
    layerGroups: {},
    currentItem: null,
    styleDialogKey: 0,
    styleDialogStatus: false
  }),
  components: {
    LayerOrder,
    InLegend,
    StyleDialog
  },
  computed: {
    ...mapGetters("app", {
      appConfig: "appConfig",
      appColor: "appColor"
    }),
    ...mapFields("app", {
      layerTabIndex: "layerTabIndex"
    })
  },
  mounted() {
    EventBus.$on("updateStyleDialogStatusForLayerTree", value => {
      this.styleDialogStatus = value;
    });
  },
  methods: {
    /**
     * This function is executed, after the map is bound (see mixins/Mapable)
     * and registers the current map layers.
     */
    onMapBound() {
      const layerGroups = this.appConfig.layer_groups;
      layerGroups.reverse().forEach(lg => {
        const layerGroupName = Object.keys(lg)[0];
        if (layerGroupName !== "heatmap") {
          this.layerGroups[layerGroupName] = [];
        }
      });
      this.map
        .getLayers()
        .getArray()
        .forEach(layer => {
          if (layer.get("group") && layer.get("group") !== "heatmap") {
            if (!this.layerGroups[layer.get("group")]) {
              this.layerGroups[layer.get("group")] = [];
            }
            this.layerGroups[layer.get("group")].push(layer);
          }
        });
    },
    openStyleDialog(item) {
      //This function is used for opening Style Setting dialog component for a layer
      EventBus.$emit("updateStyleDialogStatusForLayerOrder", false);
      this.styleDialogStatus = true;
      if (
        this.currentItem &&
        this.currentItem.get("name") !== item.get("name")
      ) {
        this.styleDialogKey += 1;
      }
      if (
        this.currentItem &&
        this.currentItem.get("layerTreeKey") >= 0 &&
        this.currentItem.get("name") !== item.get("name")
      ) {
        this.currentItem.set(
          "layerTreeKey",
          this.currentItem.get("layerTreeKey") + 1
        );
      }
      this.currentItem = item;
    },
    toggleLayerVisibility(layer, group) {
      const currentState = layer.getVisible();
      //Turn off other layers if layer group is background layers.
      if (layer.get("group") === "basemap") {
        group.forEach(layer => {
          layer.setVisible(false);
        });
      }
      layer.setVisible(!currentState);
      if (layer.getVisible() === false) {
        layer.set("showOptions", false);
      } else {
        layer.set("showOptions", true);
      }
      EventBus.$emit("toggleLayerVisiblity", layer);
    },
    toggleLayerOptions(layer) {
      layer.set("showOptions", !layer.get("showOptions"));
    },
    changeLayerOpacity(value, layer) {
      layer.setOpacity(value);
    },
    getLayerGroupIcon(group) {
      const layerGroupConf = this.appConfig.layer_groups.filter(g => g[group]);
      return layerGroupConf[0][group].icon || "fas fa-layer-group";
    },
    translate(type, key) {
      //type = {layerGroup || layerName}
      //Checks if key exists and translates it othewise return the input value
      const canTranslate = this.$te(`map.${type}.${key}`);
      if (canTranslate) {
        return this.$t(`map.${type}.${key}`);
      } else {
        return key;
      }
    }
  }
};
</script>
<style lang="css" scoped>
.v-expansion-panel__header {
  cursor: default;
}
.active-icon {
  color: #30c2ff;
}

.expansion-panel__container--active {
  background-color: white !important;
}

.checkbox >>> .v-input__control {
  height: 25px;
}

.v-expansion-panel-content >>> .v-expansion-panel-content__wrap {
  padding: 0px;
}

.v-expansion-panel-content >>> .v-input__slot {
  margin-bottom: 0px;
}

.layer-row >>> .v-expansion-panel-header {
  cursor: auto;
}
</style>
