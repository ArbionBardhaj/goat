// cppimport

/*PGR-GNU*****************************************************************
File: isochrone.cpp
Copyright (c) 2021 Majk Shkurti, <majk.shkurti@plan4better.de>
Copyright (c) 2020 Vjeran Crnjak, <vjeran@crnjak.xyz>
------
This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 ********************************************************************PGR-GNU*/

#include <iostream>
#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <sstream>
#include <unordered_map>
#include <vector>
#include <string>
#include <cstring>
#include <exception>
#include "concaveman.h"
#include <map>


#ifdef DEBUG
#include <fstream>
#include <regex>
#include <iterator>
#endif

#ifndef DEBUG
#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>
namespace py = pybind11;
#endif

// ---------------------------------------------------------------------------------------------------------------------
// ***************************************** ISOCHRONE COMPUTATION *****************************************************
// ---------------------------------------------------------------------------------------------------------------------

typedef struct
{
  int64_t id;
  int64_t source;
  int64_t target;
  double cost;
  double reverse_cost;
  double length;
  std::vector<std::array<double, 2>> geometry;
} Edge;

typedef struct
{
  int64_t start_id;
  int64_t edge;
  double start_perc;
  double end_perc;
  double start_cost;
  double end_cost;
  std::vector<std::array<double, 2>> geometry;
} IsochroneNetworkEdge;

typedef struct
{
  int64_t start_id;
  std::unordered_map<int32_t, std::vector<std::array<double, 2>>> shape; // steps, geometry
} IsochroneStartPoint;

typedef struct
{
  std::vector<IsochroneStartPoint> isochrone;
  std::vector<IsochroneNetworkEdge> network;
} Result;

// Adjacency list for the isochrone network (for each node, the edges that are connected to it)
std::vector<std::vector<const Edge *>>
construct_adjacency_list(size_t n, const Edge *edges,
                         size_t total_edges)
{
  std::vector<std::vector<const Edge *>> adj(n);
  for (size_t i = 0; i < total_edges; ++i)
  {
    if (edges[i].cost >= 0.)
    {
      adj[edges[i].source].push_back(&edges[i]);
    }
    if (edges[i].reverse_cost >= 0.)
    {
      adj[edges[i].target].push_back(&edges[i]);
    }
  }
  return adj;
}

// Dijkstra's algorithm one-to-all shortest path search

void dijkstra(int64_t start_vertex, double driving_distance,
              const std::vector<std::vector<const Edge *>> &adj,
              std::vector<int64_t> *predecessors,
              std::vector<double> *distances)
{
  size_t n = adj.size();
  distances->assign(n, std::numeric_limits<double>::infinity());
  predecessors->assign(n, -1);
  typedef std::tuple<double, int64_t> pq_el; // <agg_cost at node, node id>
  std::set<pq_el> q;                         // priority queue
  q.insert({0., start_vertex});
  while (!q.empty())
  {
    double dist;
    int64_t node_id;
    std::tie(dist, node_id) = *q.begin();
    if (dist >= driving_distance)
    {
      break;
    }
    q.erase(q.begin());
    for (auto &&e : adj[node_id])
    {
      int64_t target = e->target == node_id ? e->source : e->target;
      double cost = e->target == node_id ? e->reverse_cost : e->cost;
      double agg_cost = dist + cost;
      if ((*distances)[target] > agg_cost)
      {
        q.erase({(*distances)[target], target});
        (*distances)[target] = agg_cost;
        (*predecessors)[target] = node_id;
        q.emplace((*distances)[target], target);
      }
    }
  }
}

std::unordered_map<int64_t, int64_t> remap_edges(Edge *data_edges,
                                                 size_t total_edges)
{
  std::unordered_map<int64_t, int64_t> mapping;
  int64_t id = 0;
  for (size_t i = 0; i < total_edges; ++i)
  {
    Edge *e = data_edges + i;
    int64_t source_id, target_id;
    auto it = mapping.find(e->source);
    // better with if-initialization-statement
    if (it != mapping.end())
    {
      source_id = it->second;
    }
    else
    {
      source_id = id++;
      mapping[e->source] = source_id;
    }
    it = mapping.find(e->target);
    if (it != mapping.end())
    {
      target_id = it->second;
    }
    else
    {
      target_id = id++;
      mapping[e->target] = target_id;
    }
    e->source = source_id;
    e->target = target_id;
  }
  return mapping;
}

// ---------------------------------------------------------------------------------------------------------------------
// CONVEX HULL ALGORITHM
// ---------------------------------------------------------------------------------------------------------------------
// Implementation of Andrew's monotone chain 2D convex hull algorithm.
// Asymptotic complexity: O(n log n).
// Practical performance: 0.5-1.0 seconds for n=1000000 on a 1GHz machine.
struct ConvexhullResult
{
  std::vector<std::array<double, 2>> shape;
  std::vector<int32_t> indices;
};

struct
{
  bool operator()(std::array<double, 2> &pt1, std::array<double, 2> &pt2) const
  {
    return pt1[0] < pt2[0] || (pt1[0] == pt2[0] && pt1[1] < pt2[1]);
  }
} customLess;

// Returns a positive value, if OAB makes a counter-clockwise turn,
// negative for clockwise turn, and zero if the points are collinear.
double cross(const std::array<double, 2> &O, const std::array<double, 2> &A, const std::array<double, 2> &B)
{
  return (A[0] - O[0]) * (B[1] - O[1]) - (A[1] - O[1]) * (B[0] - O[0]);
}

// Returns a list of points on the convex hull in counter-clockwise order.
// Note: the last point in the returned list is the same as the first one.
ConvexhullResult convexhull(std::vector<std::array<double, 2>> &P)
{
  ConvexhullResult result;

  size_t n = P.size(), k = 0;

  if (n <= 3)
    throw std::invalid_argument("Number of points must be 3 or more!");

  std::vector<std::array<double, 2>> H(2 * n);
  std::vector<int32_t> H_indices(2 * n); // of ordered points

  // Sort points lexicographically
  std::sort(P.begin(), P.end(), customLess);

  // Build lower hull
  for (size_t i = 0; i < n; ++i)
  {
    while (k >= 2 && cross(H[k - 2], H[k - 1], P[i]) <= 0)
      k--;
    H[k++] = P[i];
    H_indices[k - 1] = i;
  }

  // Build upper hull
  for (size_t i = n - 1, t = k + 1; i > 0; --i)
  {
    while (k >= t && cross(H[k - 2], H[k - 1], P[i - 1]) <= 0)
      k--;
    H[k++] = P[i - 1];
    H_indices[k - 1] = i - 1;
  }

  H.resize(k - 1);
  H_indices.resize(k - 1);

  result.shape = H;
  result.indices = H_indices;
  return result;
}

// ---------------------------------------------------------------------------------------------------------------------
// LINE SUBSTRING ALGORITHM
// ---------------------------------------------------------------------------------------------------------------------

std::vector<std::array<double, 2>> line_substring(const double &start_perc, const double &end_perc, const std::vector<std::array<double, 2>> &geometry, const double &total_length)
{
  std::vector<std::array<double, 2>> line_substring;
  // Start percentage must be smaller than end percentage.
  double start_perc_ = start_perc;
  double end_perc_ = end_perc;
  if (start_perc_ > end_perc_)
  {
    std::swap(start_perc_, end_perc_);
  }
  double start_dist = start_perc_ * total_length;
  double end_dist = end_perc_ * total_length;
  auto size = geometry.size();

  bool start_reached = false;
  double accumulated_dist = 0.;
  for (size_t i = 0; i < size - 1; ++i)
  {
    // Edge cases check.
    if (start_perc_ == 1)
    {
      line_substring.push_back(geometry[size - 1]);
      break;
    }
    if (end_perc_ == 0)
    {
      line_substring.push_back(geometry[0]);
      break;
    }

    // Find segment distance (sqrt((x1-x2)^2 + (y1-y2)^2))
    double x1 = geometry[i][0];
    double y1 = geometry[i][1];
    double x2 = geometry[i + 1][0];
    double y2 = geometry[i + 1][1];
    double dx = x1 - x2;
    double dy = y1 - y2;
    double segment_dist = sqrt(pow(dx, 2) + pow(dy, 2));
    double dist_at_coord = accumulated_dist;
    accumulated_dist += segment_dist;
    if (i == 0 && start_perc_ == 0)
    {
      line_substring.push_back(geometry[0]);
      start_reached = true;
    }
    // Interpolate at start percentage and push to line_substring
    if (accumulated_dist >= start_dist && !start_reached)
    {
      double d2 = start_dist - dist_at_coord;
      double x = x1 - ((d2 * dx) / segment_dist);
      double y = y1 - ((d2 * dy) / segment_dist);
      line_substring.push_back({x, y});
      start_reached = true;
    }

    if (i == size - 2 && end_perc_ == 1)
    {
      line_substring.push_back(geometry[size - 1]);
      break;
    }
    // Interpolate at end percentage, push to line_substring and break
    if (accumulated_dist >= end_dist)
    {
      double d2 = end_dist - dist_at_coord;
      double x = x1 - ((d2 * dx) / segment_dist);
      double y = y1 - ((d2 * dy) / segment_dist);
      line_substring.push_back({x, y});
      break;
    }
    // Push midpoints to line_substring
    if (start_reached)
    {
      line_substring.push_back(geometry[i + 1]);
    }
  }
  return line_substring;
}

void reverse_isochrone_path(IsochroneNetworkEdge &isochrone_path)
{
  // reverse the percantage
  double nstart_perc = 1. - isochrone_path.end_perc;
  isochrone_path.end_perc = 1. - isochrone_path.start_perc;
  isochrone_path.start_perc = nstart_perc;
  // reversing the cost
  std::swap(isochrone_path.start_cost, isochrone_path.end_cost);
}

void append_edge_result(const int64_t &start_v, const int64_t &edge_id, const double &cost_at_node, const double &edge_cost, const double &edge_length, const std::vector<std::array<double, 2>> &geometry,
                        const std::vector<double> &distance_limits,
                        std::vector<IsochroneNetworkEdge> *isochrone_network, std::unordered_map<double, std::vector<std::array<double, 2>>> &coordinates, const bool &is_reverse)
{
  double current_cost = cost_at_node;
  double travel_cost = edge_cost;
  double start_perc = 0.;

  for (auto &dl : distance_limits)
  {
    if (cost_at_node >= dl)
    {
      continue;
    }
    double cost_at_target = current_cost + travel_cost;
    IsochroneNetworkEdge r;
    r.start_id = start_v;
    r.edge = edge_id;
    // Full edge
    if (cost_at_target < dl)
    {

      r.start_perc = start_perc;
      r.end_perc = 1.;
      r.start_cost = current_cost;
      r.end_cost = cost_at_target;
      r.geometry = geometry;
      if (is_reverse)
      {
        reverse_isochrone_path(r);
      }
      isochrone_network->push_back(r);
      std::copy(r.geometry.begin(), r.geometry.end(), std::back_inserter(coordinates[dl]));
      break;
    }
    // Partial Edge: (cost_at_target is bigger than the limit, partial edge)
    travel_cost = cost_at_target - dl; // remaining travel cost
    double partial_travel = dl - current_cost;
    r.start_perc = start_perc;
    r.end_perc = start_perc + partial_travel / edge_cost;
    r.start_cost = current_cost;
    r.end_cost = dl;
    start_perc = r.end_perc;
    current_cost = dl;
    if (is_reverse)
    {
      reverse_isochrone_path(r);
    }
    r.geometry = line_substring(r.start_perc, r.end_perc, geometry, edge_length);
    isochrone_network->push_back(r);
    std::copy(r.geometry.begin(), r.geometry.end(), std::back_inserter(coordinates[dl]));
    // A ---------- B
    // 5    7    9  10
  }
}

Result compute_isochrone(Edge *data_edges, size_t total_edges,
                         std::vector<int64_t> start_vertices,
                         std::vector<double> distance_limits,
                         bool only_minimum_cover)
{
  Result result;
  std::sort(distance_limits.begin(), distance_limits.end());
  // Using max distance limit for a single dijkstra call. After that we will
  // postprocess the results and mark the visited edges.
  double max_dist_cutoff = *distance_limits.rbegin();
  // Extracting vertices and mapping the ids from 0 to N-1. Remapping is done
  // so that data structures used can be simpler (arrays instead of maps).
  // modifying data_edges source/target fields.
  std::unordered_map<int64_t, int64_t> mapping = remap_edges(data_edges, total_edges);

  std::unordered_map<int64_t, int64_t> mapping_reversed;

  for (auto i=mapping.begin(); i!=mapping.end(); ++i)
    mapping_reversed[i->second] = i->first;

  // coordinates for the network edges for each distance limit to be used in constructing the isochrone shape
  std::unordered_map<double, std::vector<std::array<double, 2>>> coordinates;
  size_t nodes_count = mapping.size();
  std::vector<IsochroneNetworkEdge> isochrone_network;
  std::vector<IsochroneStartPoint> isochrone_start_point;
  for (auto &dl : distance_limits)
  {
    coordinates.emplace(dl, std::vector<std::array<double, 2>>());
  }
  auto adj =
      construct_adjacency_list(mapping.size(), data_edges, total_edges);
  // Storing the result of dijkstra call and reusing the memory for each vertex.
  std::vector<double> distances(nodes_count);
  std::vector<int64_t> predecessors(nodes_count);
  for (int64_t start_v : start_vertices)
  {
    auto it = mapping.find(start_v);
    // If start_v did not appear in edges then it has no particular mapping
    if (it == mapping.end())
    {
      IsochroneNetworkEdge r;
      r.start_id = start_v;
      // -2 tags the unmapped starting vertex and won't use the reverse_mapping
      // because mapping does not exist. -2 is changed to -1 later.
      r.edge = -1;
      r.start_perc = 0.0;
      r.end_perc = 0.0;
      r.geometry = {{0, 0}, {0, 0}};
      isochrone_network.push_back(r);
      continue;
    }
    // Calling the dijkstra algorithm and storing the results in predecessors
    // and distances.

    dijkstra(it->second,
             /* driving_distance */ max_dist_cutoff, adj, &predecessors,
             &distances);
    // Appending the row results.
    for (size_t i = 0; i < total_edges; ++i)
    {
      const Edge &e = *(data_edges + i);
      double scost = distances[e.source];
      double tcost = distances[e.target];
      bool s_reached = !(std::isinf(scost) || scost > max_dist_cutoff);
      bool t_reached = !(std::isinf(tcost) || tcost > max_dist_cutoff);
      if (!s_reached && !t_reached)
      {
        continue;
      }
      bool skip_st = false;
      bool skip_ts = false;
      if (only_minimum_cover)
      {
        double st_dist = scost + e.cost;
        double ts_dist = tcost + e.reverse_cost;
        bool st_fully_covered = st_dist <= max_dist_cutoff;
        bool ts_fully_covered = ts_dist <= max_dist_cutoff;
        skip_ts = st_fully_covered && ts_fully_covered && st_dist < ts_dist;
        skip_st = st_fully_covered && ts_fully_covered && ts_dist < st_dist;
      }

      if (start_v == mapping_reversed.find(e.source)->second)
      {
        append_edge_result(start_v, e.id, 0, e.cost, e.length, e.geometry, distance_limits, &isochrone_network, coordinates, true);
      }
      if (start_v == mapping_reversed.find(e.target)->second)
      {
        append_edge_result(start_v, e.id, 0, e.reverse_cost, e.length, e.geometry, distance_limits, &isochrone_network, coordinates, true);
      }
      if (!skip_ts && t_reached && predecessors[e.target] != e.source)
      {
        append_edge_result(start_v, e.id, tcost, e.reverse_cost, e.length, e.geometry, distance_limits, &isochrone_network, coordinates, true);
      }
      if (!skip_st && s_reached && predecessors[e.source] != e.target)
      {
        append_edge_result(start_v, e.id, scost, e.cost, e.length, e.geometry, distance_limits, &isochrone_network, coordinates, false);
      }
    }
    // Calculating the isochrone shape for the current starting vertex.

    IsochroneStartPoint isp;
    isp.start_id = start_v;
    for (auto &dl : distance_limits)
    {

      if (coordinates[dl].size() > 1)
      {
        auto &points_ = coordinates[dl];
        std::vector<std::array<double, 2>> isochrone_path;
        if (points_.size() > 3)
        {
          ConvexhullResult hull = convexhull(points_);
          isochrone_path = concaveman<double, 16>(points_, hull.indices);
        }
        else
        {
          isochrone_path = {{0, 0}};
        }
        coordinates[dl].clear();
        isp.shape.emplace(dl, isochrone_path);
      }
    }
    isochrone_start_point.push_back(isp);
  }

  result.isochrone = isochrone_start_point;
  result.network = isochrone_network;
  return result;
}

#ifdef DEBUG
std::vector<std::string> split(const std::string &input, const std::string &regex = " ")
{
  std::regex re(regex);
  std::sregex_token_iterator first{input.begin(), input.end(), re, -1}, last; // the '-1' is what makes the regex split (-1 := what was not matched)
  std::vector<std::string> tokens{first, last};
  return tokens;
}

std::vector<Edge>
read_file(std::string name_file)
{
  std::vector<Edge> data_edges;
  Edge edge;
  std::ifstream myfile;
  std::string line;
  myfile.open(name_file, std::ios::in);

  int lineCount = 0;
  std::getline(myfile, line); // ignore header line
  while (std::getline(myfile, line) && !line.empty())
  {
    std::vector<std::string> segmented = split(line, "(\\,\\[\\[)");
    std::vector<std::string> props = split(segmented[0], "(\\,)");
    edge.id = std::stoll(props[0]);
    edge.source = std::stoll(props[1]);
    edge.target = std::stoll(props[2]);
    edge.cost = std::stod(props[3]);
    edge.reverse_cost = std::stod(props[4]);
    edge.length = std::stod(props[5]);
    // Remove last brackets ]] and split geometry coordinate pairs.
    segmented[1].erase(segmented[1].length() - 2);
    std::vector<std::string> coords = split(segmented[1], "(\\]\\,\\[)");

    // Loop through coords
    std::vector<std::array<double, 2>> geometry;
    for (auto coord : coords)
    {
      std::array<double, 2> xy;
      std::vector<std::string> xy_str = split(coord, "(\\,)");
      xy[0] = std::stod(xy_str[0]);
      xy[1] = std::stod(xy_str[1]);
      geometry.push_back(xy);
    }
    edge.geometry = geometry;
    data_edges.push_back(edge);
    lineCount++;
  }

  myfile.close();
  return data_edges;
}

int main()
{
  std::cout << "Main function...(Testing)!";
  std::vector<std::array<double, 2>> points_ = {{0, 0}, {0.25, 0.15}, {1, 0}, {1, 1}};
  auto convex_hull = convexhull(points_);
  auto concave_points = concaveman<double, 16>({{0, 0}, {0.25, 0.15}, {1, 0}, {1, 1}}, {0, 2, 3}, 2, 0);

  // demo network file location
  std::string network_file = "../data/test_network.csv";
  std::vector<Edge> data_edges_vector = read_file(network_file);
  static const int64_t total_edges = data_edges_vector.size();
  Edge *data_edges = new Edge[total_edges];
  for (int64_t i = 0; i < total_edges; ++i)
  {
    data_edges[i] = data_edges_vector[i];
  }
  data_edges_vector.clear();
  std::vector<double> distance_limits = {60};
  std::vector<int64_t> start_vertices{2147483647};
  bool only_minimum_cover = false;
  auto results = compute_isochrone(data_edges, total_edges, start_vertices,
                                   distance_limits, only_minimum_cover);

  return 0;
}
#endif

// ---------------------------------------------------------------------------------------------------------------------
// pybind11 bindings
// ---------------------------------------------------------------------------------------------------------------------
#ifndef DEBUG

struct Isochrone
{
  // Calculate isochrone for a given set of start vertices.
  Result calculate(
      py::array_t<int64_t> &edge_ids_, py::array_t<int64_t> &sources_,
      py::array_t<int64_t> &targets_, py::array_t<double> &costs_,
      py::array_t<double> &reverse_costs_, py::array_t<double> &length_, std::vector<std::vector<std::array<double, 2>>> &geometry,
      py::array_t<int64_t> start_vertices_,
      py::array_t<double> distance_limits_,
      bool only_minimum_cover_)
  {
    auto total_edges = edge_ids_.shape(0);

    auto edge_ids_c = edge_ids_.unchecked<1>();
    auto sources_c = sources_.unchecked<1>();
    auto targets_c = targets_.unchecked<1>();
    auto costs_c = costs_.unchecked<1>();
    auto reverse_costs_c = reverse_costs_.unchecked<1>();
    auto length_c = length_.unchecked<1>();

    auto start_vertices_c = start_vertices_.unchecked<1>();
    auto total_start_vertices = start_vertices_.shape(0);

    auto distance_limits_c = distance_limits_.unchecked<1>();
    auto total_distance_limits = distance_limits_.shape(0);

    bool only_minimum_cover = only_minimum_cover_;
    Edge *data_edges = new Edge[total_edges];

    for (int64_t i = 0; i < total_edges; ++i)
    {
      data_edges[i].id = edge_ids_c(i);
      data_edges[i].source = sources_c(i);
      data_edges[i].target = targets_c(i);
      data_edges[i].cost = costs_c(i);
      data_edges[i].reverse_cost = reverse_costs_c(i);
      data_edges[i].length = length_c(i);
      data_edges[i].geometry = geometry[i];
    }

    std::vector<int64_t> start_vertices(total_start_vertices);
    for (int64_t i = 0; i < total_start_vertices; ++i)
    {
      start_vertices[i] = start_vertices_c[i];
    }
    std::vector<double> distance_limits(total_distance_limits);
    for (int64_t i = 0; i < total_distance_limits; ++i)
    {
      distance_limits[i] = distance_limits_c[i];
    }
    auto isochrone_points = compute_isochrone(data_edges, total_edges, start_vertices,
                                              distance_limits, only_minimum_cover);
    return isochrone_points;
  }
};

PYBIND11_MODULE(isochrone, m)
{
  m.doc() = "Isochrone Calculation";
  // m.def("isochrone", &isochrone, "Isochrone Calculation");
  py::class_<IsochroneStartPoint>(m, "IsochroneShape")
      .def_readwrite("start_id", &IsochroneStartPoint::start_id)
      .def_readwrite("shape", &IsochroneStartPoint::shape);

  py::class_<IsochroneNetworkEdge>(m, "IsochroneNetworkEdge")
      .def_readwrite("start_id", &IsochroneNetworkEdge::start_id)
      .def_readwrite("edge", &IsochroneNetworkEdge::edge)
      .def_readwrite("start_perc", &IsochroneNetworkEdge::start_perc)
      .def_readwrite("end_perc", &IsochroneNetworkEdge::end_perc)
      .def_readwrite("start_cost", &IsochroneNetworkEdge::start_cost)
      .def_readwrite("end_cost", &IsochroneNetworkEdge::end_cost)
      .def_readwrite("shape", &IsochroneNetworkEdge::geometry);

  py::class_<Result>(m, "Result")
      .def_readwrite("isochrone", &Result::isochrone)
      .def_readwrite("network", &Result::network);

  // bindings to Isochrone class
  py::class_<Isochrone>(m, "Isochrone")
      .def(py::init<>())
      .def("calculate", &Isochrone::calculate);
}

/*

*/
#endif
