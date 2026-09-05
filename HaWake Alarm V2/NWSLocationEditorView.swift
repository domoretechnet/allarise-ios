//
//  NWSLocationEditorView.swift
//  HaWake Alarm V2
//
//  Add or edit a monitored NWS alert location.
//  Supports searching by address/place name or using the device's current location.
//

import SwiftUI
import MapKit

struct NWSLocationEditorView: View {
    @Bindable var settings: DeviceSettings
    /// Pass an existing location to edit it; nil = add new.
    var existingLocation: NWSMonitoredLocation?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var useCurrentLocation = false
    @State private var searchText: String = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var isSearching = false
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
        span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
    )

    private var isEditing: Bool { existingLocation != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (useCurrentLocation || selectedCoordinate != nil)
    }

    var body: some View {
        Form {
            Section("Location Name") {
                TextField("e.g. Home, Office, Parents", text: $name)
                    .textInputAutocapitalization(.words)
            }

            Section {
                Toggle("Use Current Location (GPS)", isOn: $useCurrentLocation)
            } footer: {
                if useCurrentLocation {
                    Text("Will use your device's GPS coordinates each time alerts are checked.")
                }
            }

            if !useCurrentLocation {
                Section("Search for Location") {
                    HStack {
                        TextField("Address or place name", text: $searchText)
                            .textInputAutocapitalization(.words)
                            .onSubmit { performSearch() }

                        if isSearching {
                            ProgressView()
                        } else {
                            Button("Search") { performSearch() }
                                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                if !searchResults.isEmpty {
                    Section("Results") {
                        ForEach(searchResults, id: \.self) { item in
                            Button {
                                selectResult(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unknown")
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if let address = formattedAddress(for: item) {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if let coord = selectedCoordinate {
                    Section("Selected Location") {
                        Map {
                            Marker(name, coordinate: coord)
                                .tint(.red)
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                        Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Location" : "Add Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            if let existing = existingLocation {
                name = existing.name
                useCurrentLocation = existing.useCurrentLocation
                if !existing.useCurrentLocation {
                    selectedCoordinate = CLLocationCoordinate2D(
                        latitude: existing.latitude,
                        longitude: existing.longitude
                    )
                    mapRegion = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: existing.latitude, longitude: existing.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                    )
                }
            }
        }
    }

    // MARK: - Search

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            isSearching = false
            if let response {
                searchResults = Array(response.mapItems.prefix(5))
            } else {
                searchResults = []
            }
        }
    }

    private func selectResult(_ item: MKMapItem) {
        selectedCoordinate = item.location.coordinate
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = item.name ?? ""
        }
        searchResults = []
    }

    private func formattedAddress(for item: MKMapItem) -> String? {
        // TODO: migrate to MKAddress when iOS 26 MKAddress property names are confirmed
        let p = item.placemark
        return [p.subThoroughfare, p.thoroughfare, p.locality, p.administrativeArea, p.postalCode]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    // MARK: - Save

    private func save() {
        var locs = settings.nwsMonitoredLocations

        if let existing = existingLocation, let idx = locs.firstIndex(where: { $0.id == existing.id }) {
            locs[idx].name = name.trimmingCharacters(in: .whitespaces)
            locs[idx].useCurrentLocation = useCurrentLocation
            if !useCurrentLocation, let coord = selectedCoordinate {
                locs[idx].latitude = coord.latitude
                locs[idx].longitude = coord.longitude
            }
        } else {
            var newLoc: NWSMonitoredLocation
            if useCurrentLocation {
                newLoc = NWSMonitoredLocation(name: name.trimmingCharacters(in: .whitespaces), useCurrentLocation: true)
            } else if let coord = selectedCoordinate {
                newLoc = NWSMonitoredLocation(
                    name: name.trimmingCharacters(in: .whitespaces),
                    latitude: coord.latitude,
                    longitude: coord.longitude
                )
            } else {
                return
            }
            locs.append(newLoc)
        }

        settings.nwsMonitoredLocations = locs

        // Restart service if running to pick up new location
        if settings.nwsAlertsEnabled {
            NWSAlertService.shared.stop()
            NWSAlertService.shared.start()
        }

        dismiss()
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
