/**
 * Util class for Isochrone Calculation
 */

const IsochroneUtils = {
  getCalculationFeatures: function getCalculationFeatures(
    calculation,
    IsochroneLayer
  ) {
    let data = calculation.data;
    let isochroneFeatures = [];
    if (data) {
      data.forEach(isochrone => {
        let id = isochrone.id;
        let feature = IsochroneLayer.getSource().getFeatureById(id);
        if (feature) {
          isochroneFeatures.push(feature);
        }
      });
    }

    return isochroneFeatures;
  },
  getCalculationPoisObject: function getCalculationPoisObject(
    isochroneFeatures
  ) {
    let obj = {};
    if (isochroneFeatures.length > 0) {
      isochroneFeatures.forEach(isochrone => {
        let modus = isochrone.get("modus");
        let time = isochrone.get("step");
        let pois = isochrone.get("sum_pois");
        if (!obj[modus]) {
          obj[modus] = {};
        }
        obj[modus][time] = pois;
      });
    }
    return obj;
  },
  getMultiIsochroneTableData: function getMultiIsochroneTableData(
    isochroneFeatures
  ) {
    let multiIsochroneTableData = [];
    isochroneFeatures.forEach(feature => {
      let obj = {
        isochrone: `${IsochroneUtils.getIsochroneAliasFromKey(
          feature.get("modus")
        )} - ${feature.get("step")} min`
      };
      const populationObj = feature.get("population");
      //Multi-isochrone is created using draw
      if (feature.get("population").bounding_box) {
        obj.studyArea = "-- (Draw)";
        obj.population = populationObj.bounding_box;
        obj.reachPopulation = populationObj.bounding_box_reached;
      } else {
        //Multi-isochrone is created from study-area
        obj.studyArea = Object.keys(populationObj[0])[0];
        obj.population = populationObj[0][Object.keys(populationObj[0])[0]];
        obj.reachPopulation =
          populationObj[0][Object.keys(populationObj[0])[1]];
      }

      multiIsochroneTableData.push(obj);
    });
    return multiIsochroneTableData;
  },
  getIsochroneAliasFromKey: function getIsochroneAliasFromKey(key) {
    let isochroneMapping = {
      "1": "Default",
      "2": "Input",
      "3": "Default",
      "4": "Input"
    };
    let alias = isochroneMapping[key] ? isochroneMapping[key] : key;
    return alias;
  }
};

export default IsochroneUtils;
